"""PersonaClient: one persona = one independent WebSocket connection.

Several personas share one process (and one loaded model), but the server
sees N unrelated participants — the federation contract stays honest, and
the same harness later runs a single persona on someone else's laptop
unchanged.

State machine per connection:

    dial (HTTP) → connect → join → mirror transcript
        on beat          → compute urge (pure, instant) → bid
        on grant         → generate (cancellable) → typing delay → speak
        on grant_revoked → cancel the in-flight generation
        on speak_rejected→ discard silently (context went stale)
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
from typing import Any
from urllib.parse import urlsplit

import httpx
import websockets

from .inference.engine import Engine
from .pacing import typing_delay
from .persona import Persona
from .urge import compute_urge

log = logging.getLogger("party_line")

RECONNECT_DELAYS = [1, 2, 5, 10, 30]


class PersonaClient:
    def __init__(
        self,
        persona: Persona,
        engine: Engine,
        server_url: str,
        *,
        rng: random.Random | None = None,
        typing_scale: float = 1.0,
    ):
        self.persona = persona
        self.engine = engine
        self.server_url = server_url.rstrip("/")
        self.rng = rng or random.Random()
        self.typing_scale = typing_scale

        self.participant_id: str | None = None
        self.topic: str = ""
        self.roster: list[dict[str, Any]] = []
        self.transcript: list[dict[str, Any]] = []
        self.beats_since_message = 0

        self._generation: asyncio.Task | None = None
        self._cancel = asyncio.Event()

    # ── Lifecycle ──────────────────────────────────────────────────────────

    async def run(self) -> None:
        attempt = 0
        while True:
            try:
                await self._session()
                attempt = 0
            except (OSError, websockets.WebSocketException) as exc:
                delay = RECONNECT_DELAYS[min(attempt, len(RECONNECT_DELAYS) - 1)]
                attempt += 1
                log.warning("%s: connection lost (%s); redialing in %ss", self.persona.name, exc, delay)
                await asyncio.sleep(delay)

    async def _session(self) -> None:
        async with httpx.AsyncClient() as http:
            resp = await http.post(f"{self.server_url}/api/dial", json={"kind": "bot", "name": self.persona.name})
            resp.raise_for_status()
            dial = resp.json()

        ws_url = self._ws_url(dial["ws_url"])
        async with websockets.connect(ws_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "join",
                        "name": self.persona.name,
                        "kind": "bot",
                        "room_id": dial["room_id"],
                        "ticket": dial.get("ticket"),
                    }
                )
            )
            async for frame in ws:
                await self._handle(ws, json.loads(frame))

    def _ws_url(self, path: str) -> str:
        parts = urlsplit(self.server_url)
        scheme = "wss" if parts.scheme == "https" else "ws"
        return f"{scheme}://{parts.netloc}{path}"

    # ── Event handling ─────────────────────────────────────────────────────

    async def _handle(self, ws, event: dict[str, Any]) -> None:
        match event.get("type"):
            case "welcome":
                self.participant_id = event["participant_id"]
                self.topic = event["room"]["topic"]
                self.roster = event["roster"]
                self.transcript = list(event["transcript"])
                log.info(
                    "%s: on the line in %s (topic: %s, %d others)",
                    self.persona.name,
                    event["room"]["id"],
                    self.topic,
                    len(self.roster) - 1,
                )

            case "message":
                self.transcript.append(event)
                self.beats_since_message = 0
                log.info("%s heard %s: %s", self.persona.name, event["sender"]["name"], event["body"])

            case "presence":
                self._presence(event)

            case "beat":
                self.beats_since_message += 1
                urge = compute_urge(
                    self.persona,
                    self.transcript,
                    beats_since_message=self.beats_since_message,
                    rng=self.rng,
                )
                if urge > 0:
                    await ws.send(json.dumps({"type": "bid", "beat_id": event["beat_id"], "urge": urge}))

            case "grant":
                self._start_generation(ws, event)

            case "grant_revoked":
                log.info("%s: grant revoked (%s)", self.persona.name, event.get("reason"))
                self._cancel.set()

            case "speak_rejected":
                log.info("%s: speak rejected (%s) — discarded", self.persona.name, event.get("reason"))

            case "error":
                log.warning("%s: server error %s: %s", self.persona.name, event.get("code"), event.get("detail"))

    def _presence(self, event: dict[str, Any]) -> None:
        participant = event["participant"]
        if event["event"] == "left":
            self.roster = [p for p in self.roster if p["participant_id"] != participant["participant_id"]]
        elif all(p["participant_id"] != participant["participant_id"] for p in self.roster):
            self.roster.append(participant)

    # ── Speaking ───────────────────────────────────────────────────────────

    def _start_generation(self, ws, grant: dict[str, Any]) -> None:
        if self._generation and not self._generation.done():
            # shouldn't happen (one grant at a time), but never stack them
            self._cancel.set()

        self._cancel = asyncio.Event()
        self._generation = asyncio.create_task(self._speak(ws, grant, self._cancel))

    async def _speak(self, ws, grant: dict[str, Any], cancel: asyncio.Event) -> None:
        started = asyncio.get_running_loop().time()
        roster_names = [p["name"] for p in self.roster]

        try:
            body = await self.engine.generate(
                self.persona, self.topic, roster_names, list(self.transcript), cancel
            )
        except Exception:
            log.exception("%s: generation failed; forfeiting grant", self.persona.name)
            return

        if body is None or cancel.is_set():
            return
        body = body.strip()
        if not body:
            return

        elapsed = asyncio.get_running_loop().time() - started
        delay = typing_delay(body, elapsed, self.rng) * self.typing_scale

        # the grant deadline is a hard budget: never "type" past it, or the
        # director revokes, strikes us, and the message is wasted
        deadline_s = grant.get("deadline_ms", 25_000) / 1000
        delay = min(delay, max(0.0, deadline_s * 0.6 - elapsed))
        try:
            await asyncio.wait_for(cancel.wait(), timeout=delay)
            return  # revoked while "typing"
        except asyncio.TimeoutError:
            pass

        await ws.send(
            json.dumps({"type": "speak", "grant_id": grant["grant_id"], "body": body})
        )
        log.info("%s said: %s", self.persona.name, body)
