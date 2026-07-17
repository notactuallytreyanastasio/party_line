"""Engine protocol + the MLX implementation.

One loaded model serves every persona in the process: weights are shared,
only prompts differ. Generation is serialized behind a lock (Metal wants
one generation at a time) and runs in a thread so the persona clients
keep servicing beats while a reply is being generated. Cancellation is
between-token: the stream loop checks a threading.Event per chunk.

mlx-lm's API churns; every mlx-lm call in the harness lives in this file.
"""

from __future__ import annotations

import asyncio
import platform
import re
import threading
import time
from typing import Any, Protocol

from ..persona import Persona
from . import transcript as tr

DEFAULT_MODEL = "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"

HARMONY_FINAL = "<|channel|>final<|message|>"
HARMONY_ANALYSIS = "<|channel|>analysis<|message|>"
GEMMA_THOUGHT = "<|channel>thought"
GEMMA_CLOSE = "<channel|>"


def extract_channel_final(text: str) -> str:
    """Pull the visible reply out of a thinking model's raw output.

    Two dialects in the wild:
    - gpt-oss (harmony): analysis channel, then `<|channel|>final<|message|>`
      followed by the reply.
    - gemma-4: `<|channel>thought` opens the reasoning, a bare `<channel|>`
      closes it, and the reply follows with no label.

    If the model burned its whole budget thinking and never surfaced a
    reply, return "" — the caller forfeits the grant rather than posting
    chain-of-thought to the room. Plain (non-thinking) output passes
    through untouched.
    """
    if HARMONY_FINAL in text:
        final = text.rsplit(HARMONY_FINAL, 1)[1]
    elif GEMMA_THOUGHT in text and GEMMA_CLOSE in text:
        final = text.rsplit(GEMMA_CLOSE, 1)[1]
    elif (
        HARMONY_ANALYSIS in text
        or GEMMA_THOUGHT in text
        or text.lstrip().startswith("analysis")
    ):
        return ""
    else:
        final = text

    # strip residual control tokens of either dialect
    return re.sub(r"<\|?[a-z_]+\|?>", "", final).strip()


class Engine(Protocol):
    def capabilities(self) -> dict[str, Any]:
        """What this machine is running, for the exchange's agent directory.

        These are *claims*: the server clamps them and never trusts them. Say
        only what we actually know — an unknown is better than a guess, because
        a guess routes someone's hard question to a model that can't hold it.
        """
        ...

    async def generate(
        self,
        persona: Persona,
        topic: str,
        roster_names: list[str],
        transcript: list[dict[str, Any]],
        cancel: asyncio.Event,
        memories: list[str] | None = None,
    ) -> str | None:
        """One chat message in the persona's voice, or None if cancelled."""
        ...


class MlxEngine:
    def __init__(self, model_id: str = DEFAULT_MODEL):
        self.model_id = model_id
        self._lock = asyncio.Lock()
        self._model = None
        self._tokenizer = None
        # measured at warmup on THIS machine, not a spec-sheet number
        self._tokens_per_s = 0.0
        # Thinking models (gpt-oss harmony, gemma-4 thought channels) reason
        # in a hidden channel before the reply: budget extra tokens, don't
        # stop-scan mid-thought, and extract only the visible channel.
        lowered = model_id.lower()
        self._channels = "gpt-oss" in lowered or "gemma-4" in lowered
        self._harmony = "gpt-oss" in lowered
        # gemma-4 honors enable_thinking=False in its chat template —
        # skip the thought channel entirely (verified by probe; the
        # channel extractor stays on as belt-and-suspenders)
        self._template_kwargs = {"enable_thinking": False} if "gemma-4" in lowered else {}

    async def warmup(self) -> float:
        """Load the model and run a throwaway generation so the first grant
        doesn't pay for Metal kernel compilation. Returns tokens/sec."""
        rate = await asyncio.to_thread(self._warmup_sync)
        self._tokens_per_s = rate
        return rate

    def capabilities(self) -> dict[str, Any]:
        """Facts this machine knows about itself. Nothing derived.

        Size and quantization are NOT reported: they're already in the model
        id, and the server reads them off it. Parsing them here too meant two
        parsers in two languages, which promptly disagreed about
        "gemma-4-e4b" (the server's word boundary couldn't see the 4B inside
        the token). One parser, one answer.
        """
        return {
            "model": self.model_id,
            # 0.0 until warmup has actually timed a generation; the server
            # reads that as "hasn't said", which is the truth
            "tokens_per_s": round(self._tokens_per_s, 1),
            "hardware": _hardware(),
        }

    def _warmup_sync(self) -> float:
        from mlx_lm import load

        self._model, self._tokenizer = load(self.model_id)
        started = time.monotonic()
        text, n_tokens = self._generate_sync(
            [
                {"role": "system", "content": "You are a chat participant."},
                {"role": "user", "content": "Say hi in three words."},
            ],
            stops=[],
            max_tokens=8,
            temperature=0.7,
            cancel_check=lambda: False,
        )
        elapsed = max(time.monotonic() - started, 1e-6)
        _ = text
        return n_tokens / elapsed

    async def generate(
        self,
        persona: Persona,
        topic: str,
        roster_names: list[str],
        transcript: list[dict[str, Any]],
        cancel: asyncio.Event,
        memories: list[str] | None = None,
    ) -> str | None:
        messages = tr.render_messages(persona, topic, roster_names, transcript, memories)
        stops = tr.stop_strings(roster_names)

        max_tokens = persona.max_tokens

        if self._channels:
            # budget extra tokens for the thinking channel so the visible
            # reply still fits
            max_tokens = max(320, persona.max_tokens * 2 + 128)

        if self._harmony and messages and messages[0]["role"] == "system":
            # harmony honors an explicit reasoning-effort pin
            messages[0]["content"] += "\n\nReasoning: low"

        async with self._lock:
            if cancel.is_set():
                return None

            raw, _ = await asyncio.to_thread(
                self._generate_sync,
                messages,
                stops=stops,
                max_tokens=max_tokens,
                temperature=persona.temperature,
                cancel_check=cancel.is_set,
            )

        if cancel.is_set():
            return None
        raw = extract_channel_final(raw)
        if not raw:
            return None
        return tr.postprocess(raw, persona.name, roster_names)

    @staticmethod
    def _merge_system_into_user(messages: list[dict[str, str]]) -> list[dict[str, str]]:
        system = "\n\n".join(m["content"] for m in messages if m["role"] == "system")
        rest = [m for m in messages if m["role"] != "system"]
        if system and rest and rest[0]["role"] == "user":
            rest = [
                {"role": "user", "content": f"{system}\n\n{rest[0]['content']}"},
                *rest[1:],
            ]
        elif system:
            rest = [{"role": "user", "content": system}, *rest]
        return rest

    def _generate_sync(
        self,
        messages: list[dict[str, str]],
        *,
        stops: list[str],
        max_tokens: int,
        temperature: float,
        cancel_check,
    ) -> tuple[str, int]:
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_repetition_penalty, make_sampler

        if self._model is None:
            raise RuntimeError("call warmup() before generate()")

        # apply_chat_template returns token ids — never re-encode the
        # templated string (double-BOS quietly degrades Llama output).
        # Gemma-family templates reject the system role: fall back to
        # folding the system prompt into the first user message.
        try:
            prompt = self._tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, **self._template_kwargs
            )
        except Exception:
            merged = self._merge_system_into_user(messages)
            prompt = self._tokenizer.apply_chat_template(
                merged, add_generation_prompt=True, **self._template_kwargs
            )
        sampler = make_sampler(temp=temperature, top_p=0.95)
        logits_processors = [make_repetition_penalty(1.15, context_size=64)]

        buffer = ""
        n_tokens = 0
        for chunk in stream_generate(
            self._model,
            self._tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=sampler,
            logits_processors=logits_processors,
        ):
            if cancel_check():
                break
            buffer += chunk.text
            n_tokens += 1
            # thinking-channel output legitimately mentions roster names
            # while reasoning — stop-scan only plain chat models here;
            # channel output is trimmed after final-channel extraction.
            if not self._channels:
                cut = tr.scan_stops(buffer, stops)
                if cut is not None:
                    buffer = buffer[:cut]
                    break

        return buffer, n_tokens



def _hardware() -> str:
    bits = [platform.system(), platform.machine()]
    return " ".join(b for b in bits if b) or "unknown"
