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
import threading
import time
from typing import Any, Protocol

from ..persona import Persona
from . import transcript as tr

DEFAULT_MODEL = "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"


class Engine(Protocol):
    async def generate(
        self,
        persona: Persona,
        topic: str,
        roster_names: list[str],
        transcript: list[dict[str, Any]],
        cancel: asyncio.Event,
    ) -> str | None:
        """One chat message in the persona's voice, or None if cancelled."""
        ...


class MlxEngine:
    def __init__(self, model_id: str = DEFAULT_MODEL):
        self.model_id = model_id
        self._lock = asyncio.Lock()
        self._model = None
        self._tokenizer = None

    async def warmup(self) -> float:
        """Load the model and run a throwaway generation so the first grant
        doesn't pay for Metal kernel compilation. Returns tokens/sec."""
        return await asyncio.to_thread(self._warmup_sync)

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
    ) -> str | None:
        messages = tr.render_messages(persona, topic, roster_names, transcript)
        stops = tr.stop_strings(roster_names)

        async with self._lock:
            if cancel.is_set():
                return None

            raw, _ = await asyncio.to_thread(
                self._generate_sync,
                messages,
                stops=stops,
                max_tokens=persona.max_tokens,
                temperature=persona.temperature,
                cancel_check=cancel.is_set,
            )

        if cancel.is_set():
            return None
        return tr.postprocess(raw, persona.name, roster_names)

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
        from mlx_lm.sample_utils import make_sampler

        if self._model is None:
            raise RuntimeError("call warmup() before generate()")

        # apply_chat_template returns token ids — never re-encode the
        # templated string (double-BOS quietly degrades Llama output)
        prompt = self._tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        sampler = make_sampler(temp=temperature, top_p=0.95)

        buffer = ""
        n_tokens = 0
        for chunk in stream_generate(
            self._model,
            self._tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=sampler,
        ):
            if cancel_check():
                break
            buffer += chunk.text
            n_tokens += 1
            cut = tr.scan_stops(buffer, stops)
            if cut is not None:
                buffer = buffer[:cut]
                break

        return buffer, n_tokens
