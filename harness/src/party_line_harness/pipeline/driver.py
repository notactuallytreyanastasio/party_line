"""The driver: tokenize a prompt, walk a token through the ordered stages, and
detokenize the reply.

The driver owns all *text* — the chat template, detokenization, the eos set —
so the stages stay pure tensor engines that never load a tokenizer. Per step it
hands stage 0 the current token(s), relays the returned hidden state stage to
stage, and reads a sampled token back from the last stage; that token becomes
the next step's input.

A ``Transport`` is how the driver reaches a stage. ``LocalTransport`` calls
in-process ``PipelineStage`` objects directly (the smoke path and a single-box
demo); ``HttpTransport`` speaks the wire frame to ``serve-shard`` daemons. Both
route through the identical ``PipelineStage.step``, so a split that is correct
in-process is correct across machines — only a socket moves.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Iterable, Protocol

import numpy as np

from . import wire


class StageError(RuntimeError):
    """A specific pipeline stage failed or is unreachable — carries which one,
    so a caller can say *which machine* died instead of shrugging a 500."""

    def __init__(self, stage: int, url: str, cause: Exception):
        super().__init__(f"stage {stage} ({url}) failed: {cause}")
        self.stage = stage
        self.url = url
        self.cause = cause


class Transport(Protocol):
    """How the driver reaches the stages of one pipeline."""

    n_stages: int

    def reset(self, session: str) -> None:
        """Drop any cached state for ``session`` on every stage."""
        ...

    def call(
        self,
        stage: int,
        session: str,
        *,
        tokens: list[int] | None,
        hidden: np.ndarray | None,
        want: str,
        sample: bool,
        temperature: float,
        top_p: float,
    ) -> tuple[str, Any]:
        """Run one stage's step; return ``("hidden", ndarray)`` or ``("token", int)``."""


class LocalTransport:
    """In-process stages — used by the smoke check and single-box runs."""

    def __init__(self, stages: list[Any]):
        self.stages = stages
        self.n_stages = len(stages)

    def reset(self, session: str) -> None:
        for stage in self.stages:
            stage.reset(session)

    def call(self, stage, session, *, tokens, hidden, want, sample, temperature, top_p):
        return self.stages[stage].step(
            session,
            tokens=tokens,
            hidden=hidden,
            want=want,
            sample=sample,
            temperature=temperature,
            top_p=top_p,
        )


class HttpTransport:
    """Remote stages behind ``serve-shard`` daemons, addressed in pipeline order.

    Each endpoint is ``(url, secret)`` — the same secret gate ``serve-llm`` uses,
    so a stage never faces the open internet unauthenticated.
    """

    def __init__(self, endpoints: list[tuple[str, str | None]], *, timeout: float = 120.0):
        import httpx

        self._client = httpx.Client(timeout=timeout)
        self.endpoints = [(u.rstrip("/"), s) for u, s in endpoints]
        self.n_stages = len(endpoints)

    def reset(self, session: str) -> None:
        for stage, (url, secret) in enumerate(self.endpoints):
            self._post(stage, url, secret, "/pipeline/reset", wire.encode_frame({"session": session}))

    def call(self, stage, session, *, tokens, hidden, want, sample, temperature, top_p):
        url, secret = self.endpoints[stage]
        header = {
            "session": session,
            "want": want,
            "sample": sample,
            "temperature": temperature,
            "top_p": top_p,
        }
        if tokens is not None:
            header["tokens"] = list(tokens)
        frame = wire.encode_frame(header, hidden)
        raw = self._post(stage, url, secret, "/pipeline/forward", frame)
        resp, tensor = wire.decode_frame(raw)
        if resp.get("kind") == "token":
            return "token", int(resp["token"])
        return "hidden", tensor

    def healthz(self, *, timeout: float = 5.0) -> list[tuple[int, bool]]:
        """Preflight every hop: ``[(stage, reachable)]`` via each shard's open
        ``/healthz``. Lets a caller name the dead machine before generating."""
        import httpx

        out = []
        for stage, (url, _secret) in enumerate(self.endpoints):
            try:
                resp = self._client.get(url + "/healthz", timeout=timeout)
                out.append((stage, resp.status_code == 200))
            except httpx.HTTPError:
                out.append((stage, False))
        return out

    def _post(self, stage: int, url: str, secret: str | None, path: str, body: bytes) -> bytes:
        import httpx

        headers = {"Content-Type": "application/octet-stream"}
        if secret:
            headers["Authorization"] = f"Bearer {secret}"
        try:
            resp = self._client.post(url + path, content=body, headers=headers)
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            # attribute the failure to its hop — an anonymous error in a chain
            # of machines is undebuggable
            raise StageError(stage, url, exc) from exc
        return resp.content

    def close(self) -> None:
        self._client.close()


@dataclass(frozen=True)
class Lease:
    """A leased pipeline: the ordered ``(url, token)`` endpoints a driver
    walks, and when the tokens expire (unix seconds) — re-lease before then."""

    endpoints: list[tuple[str, str]]
    expires_at: float


def lease_pipeline(server: str, model: str, *, key: str | None, timeout: float = 10.0) -> Lease:
    """Ask the exchange to lease a ready pipeline for ``model``. Each stage's
    token is a short-lived HMAC the shard verifies against its own secret — the
    secret never travels. Raises on an incomplete pipeline (404) or auth
    failure."""
    import httpx
    import time

    headers = {"Authorization": f"Bearer {key}"} if key else {}
    resp = httpx.post(
        f"{server.rstrip('/')}/api/pipelines/lease",
        json={"model": model},
        headers=headers,
        timeout=timeout,
    )
    resp.raise_for_status()
    data = (resp.json() or {}).get("data") or {}
    stages = data.get("stages") or []
    return Lease(
        endpoints=[(s["url"], s["token"]) for s in sorted(stages, key=lambda s: s["index"])],
        expires_at=float(data.get("expires_at") or (time.time() + 3600)),
    )


def generate(
    transport: Transport,
    prompt_ids: list[int],
    *,
    max_tokens: int = 64,
    eos_ids: Iterable[int] = (),
    session: str = "s0",
    sample: bool = False,
    temperature: float = 0.7,
    top_p: float = 0.95,
    on_token: Callable[[int], None] | None = None,
) -> list[int]:
    """Run the pipeline to completion, returning the generated token ids.

    Stage 0 is fed the prompt on the first step and the last sampled token on
    each step after; the hidden state relays through the interior stages; the
    last stage samples. Stops at ``max_tokens`` or the first eos.
    """
    eos = set(eos_ids)
    n = transport.n_stages
    transport.reset(session)

    out: list[int] = []
    step_tokens: list[int] | None = list(prompt_ids)
    try:
        for _ in range(max_tokens):
            payload: Any = None
            for stage in range(n):
                want = "token" if stage == n - 1 else "hidden"
                kind, payload = transport.call(
                    stage,
                    session,
                    tokens=step_tokens if stage == 0 else None,
                    hidden=None if stage == 0 else payload,
                    want=want,
                    sample=sample,
                    temperature=temperature,
                    top_p=top_p,
                )
            token = int(payload)
            if token in eos:
                break
            out.append(token)
            if on_token is not None:
                on_token(token)
            step_tokens = [token]
    finally:
        # free the session's KV caches on every stage — best-effort, since a
        # stage that just died would otherwise mask the real error (the shards'
        # own LRU eviction is the backstop for sessions we fail to clear).
        try:
            transport.reset(session)
        except Exception:  # noqa: BLE001 - cleanup must never shadow the result
            pass
    return out


# ── tokenizer (driver-side; the stages never load one) ──────────────────────


def load_tokenizer(model_id: str) -> Any:
    """Just the tokenizer for ``model_id`` — no model weights on the driver.

    Fetches only the tokenizer/config files (never the weight shards), so a
    driver-only machine holds no model at all.
    """
    from pathlib import Path

    from huggingface_hub import snapshot_download
    from mlx_lm.utils import load_tokenizer as _load

    path = (
        model_id
        if Path(model_id).exists()
        else snapshot_download(
            model_id,
            allow_patterns=["*.json", "*.txt", "tokenizer*", "*.model"],
        )
    )
    return _load(Path(path))


def encode_prompt(tokenizer: Any, messages: list[dict[str, str]]) -> list[int]:
    """Chat-template ``messages`` to prompt token ids (with the generation
    prompt appended), matching what the model was trained to expect."""
    ids = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    return list(ids)


def eos_token_ids(tokenizer: Any) -> set[int]:
    ids = set(getattr(tokenizer, "eos_token_ids", None) or [])
    single = getattr(tokenizer, "eos_token_id", None)
    if single is not None:
        ids.add(int(single))
    return ids


def decode_tokens(tokenizer: Any, ids: list[int]) -> str:
    """Detokenize a whole generated sequence at once (non-streaming callers)."""
    detok = tokenizer.detokenizer
    detok.reset()
    for tid in ids:
        detok.add_token(tid)
    detok.finalize()
    return detok.text
