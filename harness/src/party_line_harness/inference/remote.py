"""RemoteEngine: borrow someone else's model over the tailnet.

Implements the Engine protocol by POSTing the render inputs to a host
daemon's /v1/generate (see ``serve_llm.py``) instead of loading a model
in this process. The host reconstructs the Persona and runs its own
engine; the persona clients can't tell the difference.

Sync httpx wrapped in ``asyncio.to_thread``, mirroring ``memory.client``:
the call is a slow network round-trip, so it must not block the event
loop. Cancellation is best-effort only — once the request is in flight
there is no way to recall it, so ``cancel`` is honoured on either side of
the round-trip but never mid-flight. A connection/transport error yields
None plus a single warning log, never an exception, so a host that goes
dark degrades a persona to silence rather than crashing its client.
"""

from __future__ import annotations

import asyncio
import dataclasses
import logging
from typing import Any

import httpx

from ..persona import Persona

log = logging.getLogger("party_line")


class RemoteEngine:
    def __init__(self, base_url: str, token: str | None = None, *, timeout: float = 60.0):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout

    async def generate(
        self,
        persona: Persona,
        topic: str,
        roster_names: list[str],
        transcript: list[dict[str, Any]],
        cancel: asyncio.Event,
        memories: list[str] | None = None,
    ) -> str | None:
        # best-effort cancellation: check going in …
        if cancel.is_set():
            return None

        payload = {
            "persona": dataclasses.asdict(persona),
            "topic": topic,
            "roster_names": roster_names,
            "transcript": transcript,
            "memories": memories,
        }
        text = await asyncio.to_thread(self._post, payload)

        # … and coming out (the round-trip itself can't be interrupted)
        if cancel.is_set():
            return None
        return text

    def _post(self, payload: dict[str, Any]) -> str | None:
        headers = {}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        try:
            resp = httpx.post(
                f"{self.base_url}/v1/generate",
                json=payload,
                headers=headers,
                timeout=self.timeout,
            )
            resp.raise_for_status()
            data = resp.json()
        except (httpx.HTTPError, ValueError) as exc:  # ValueError covers JSON decode
            log.warning("remote engine %s failed: %s", self.base_url, exc)
            return None
        text = data.get("text")
        return text if isinstance(text, str) else None
