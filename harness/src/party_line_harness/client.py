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
from .memory.client import DeciduousMemory
from .memory.episodic import episodic_notes
from .pacing import typing_delay
from .persona import Persona
from .urge import compute_urge

log = logging.getLogger("party_line")

RECONNECT_DELAYS = [1, 2, 5, 10, 30]

# how many heard messages accumulate before an episodic flush
FLUSH_EVERY = 25


class PersonaClient:
    def __init__(
        self,
        persona: Persona,
        engine: Engine,
        server_url: str,
        *,
        rng: random.Random | None = None,
        typing_scale: float = 1.0,
        room: str | None = None,
        memory: DeciduousMemory | None = None,
    ):
        self.persona = persona
        self.engine = engine
        self.server_url = server_url.rstrip("/")
        self.rng = rng or random.Random()
        self.typing_scale = typing_scale
        self.room = room
        self.memory = memory

        self.participant_id: str | None = None
        self.room_id: str | None = None
        self.topic: str = ""
        self.roster: list[dict[str, Any]] = []
        self.transcript: list[dict[str, Any]] = []
        self.beats_since_message = 0

        # episodic memory: flush the transcript slice since this index
        self.messages_since_flush = 0
        self._flush_index = 0

        self._generation: asyncio.Task | None = None
        self._cancel = asyncio.Event()

    # ── Lifecycle ──────────────────────────────────────────────────────────

    async def run(self) -> None:
        attempt = 0
        while True:
            try:
                await self._session()
                attempt = 0
            except (OSError, httpx.HTTPError, websockets.WebSocketException) as exc:
                # httpx errors (dial) are NOT OSErrors — a server restart
                # must mean "redial with backoff", never a dead persona
                delay = RECONNECT_DELAYS[min(attempt, len(RECONNECT_DELAYS) - 1)]
                attempt += 1
                log.warning("%s: connection lost (%s); redialing in %ss", self.persona.name, exc, delay)
                await asyncio.sleep(delay)

    async def _session(self) -> None:
        async with httpx.AsyncClient() as http:
            dial_body: dict = {"kind": "bot", "name": self.persona.name}
            if self.room:
                dial_body["room"] = self.room
            resp = await http.post(f"{self.server_url}/api/dial", json=dial_body)
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
                        # what this machine is running, for the agent
                        # directory. Claims, not proof — the server clamps
                        # them and routes on them at its own risk.
                        "capabilities": self.engine.capabilities(),
                    }
                )
            )
            try:
                async for frame in ws:
                    await self._handle(ws, json.loads(frame))
            finally:
                # never lose the tail: flush whatever we heard before the
                # line dropped (reconnect / error / clean close alike)
                await self._flush_memory()

    def _ws_url(self, path: str) -> str:
        parts = urlsplit(self.server_url)
        scheme = "wss" if parts.scheme == "https" else "ws"
        return f"{scheme}://{parts.netloc}{path}"

    # ── Event handling ─────────────────────────────────────────────────────

    async def _handle(self, ws, event: dict[str, Any]) -> None:
        match event.get("type"):
            case "welcome":
                self.participant_id = event["participant_id"]
                self.room_id = event["room"]["id"]
                self.topic = event["room"]["topic"]
                self.roster = event["roster"]
                self.transcript = list(event["transcript"])
                # the welcome backlog isn't ours to summarize; start fresh
                self._flush_index = len(self.transcript)
                self.messages_since_flush = 0
                log.info(
                    "%s: on the line in %s (topic: %s, %d others)",
                    self.persona.name,
                    self.room_id,
                    self.topic,
                    len(self.roster) - 1,
                )
                if self.memory is not None:
                    await asyncio.to_thread(self.memory.ensure_graph)

            case "message":
                self.transcript.append(event)
                self.beats_since_message = 0
                log.info("%s heard %s: %s", self.persona.name, event["sender"]["name"], event["body"])
                if self.memory is not None:
                    self.messages_since_flush += 1
                    if self.messages_since_flush >= FLUSH_EVERY:
                        await self._flush_memory()

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

            case "compose_request":
                # the boards scheduler asked this persona to write a post
                asyncio.create_task(self._write_post(ws, event))

            case "ask_request":
                # someone asked the exchange a question and the router picked
                # us. Our machine, our model, our answer.
                asyncio.create_task(self._answer(ws, event))

            case "error":
                log.warning("%s: server error %s: %s", self.persona.name, event.get("code"), event.get("detail"))

    async def _answer(self, ws, event: dict[str, Any]) -> None:
        """Answer a routed question with this machine's own model.

        Concurrent with room chat on purpose: the engine serializes generation
        behind its own lock, so an ask queues behind whatever this persona is
        saying in a room rather than racing it.

        A failure is silent here by design — the server is already holding a
        timeout for this ask, and it will tell the asker. Inventing an error
        frame would just be a second way to say the same thing.
        """
        ask_id = event.get("ask_id")
        prompt = event.get("prompt", "")
        cancel = asyncio.Event()

        try:
            body = await self.engine.generate(
                self.persona, prompt, [self.persona.name], [], cancel
            )
        except Exception:
            log.exception("%s: answering failed", self.persona.name)
            return

        if not body:
            return

        await ws.send(json.dumps({"type": "answered", "ask_id": ask_id, "body": body}))
        log.info("%s answered %s: %s", self.persona.name, ask_id, body[:60])

    async def _write_post(self, ws, event: dict[str, Any]) -> None:
        """Generate a board post on the assigned topic and send it back.

        Posts are async and low-stakes — no grant/deadline. The persona's
        own local model writes it; a failure just forfeits the assignment.
        """
        topic = event.get("topic", "")
        assignment_id = event.get("assignment_id")
        cancel = asyncio.Event()

        try:
            body = await self.engine.generate(
                self.persona, topic, [self.persona.name], [], cancel
            )
        except Exception:
            log.exception("%s: post generation failed", self.persona.name)
            return

        if not body:
            return

        await ws.send(
            json.dumps({"type": "composed", "assignment_id": assignment_id, "body": body.strip()})
        )
        log.info("%s posted to the boards: %s", self.persona.name, body[:70])

    def _presence(self, event: dict[str, Any]) -> None:
        participant = event["participant"]
        if event["event"] == "left":
            self.roster = [p for p in self.roster if p["participant_id"] != participant["participant_id"]]
        elif all(p["participant_id"] != participant["participant_id"] for p in self.roster):
            self.roster.append(participant)

    # ── Living memory ──────────────────────────────────────────────────────

    async def _flush_memory(self) -> None:
        """Summarize the transcript since the last flush and write it down.

        Runs the blocking httpx writes in a thread so beats keep flowing,
        and never raises: a memory outage must not disturb the client.
        """
        if self.memory is None:
            return
        window = self.transcript[self._flush_index :]
        if not window:
            return
        self._flush_index = len(self.transcript)
        self.messages_since_flush = 0

        notes = episodic_notes(self.persona, window, self.persona.name)
        if not notes:
            return

        def _write() -> None:
            for note in notes:
                self.memory.add_observation(note, branch=self.room_id)

        try:
            await asyncio.to_thread(_write)
        except Exception:  # pragma: no cover - add_observation already guards
            log.exception("%s: memory flush failed", self.persona.name)

    async def _recall_for(self, transcript: list[dict[str, Any]]) -> list[str] | None:
        """If the last message @-addresses me, recall up to 3 notes on the sender."""
        if self.memory is None or not transcript:
            return None
        last = transcript[-1]
        addressed = any(
            m.get("name", "").lower() == self.persona.name.lower()
            for m in last.get("mentions", []) or []
        )
        if not addressed:
            return None
        sender = (last.get("sender") or {}).get("name", "")
        if not sender:
            return None
        try:
            recalled = await asyncio.to_thread(self.memory.recall_about, sender)
        except Exception:  # pragma: no cover - recall_about already guards
            log.exception("%s: memory recall failed", self.persona.name)
            return None
        return (recalled or [])[:3] or None

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
        snapshot = list(self.transcript)
        memories = await self._recall_for(snapshot)

        try:
            body = await self.engine.generate(
                self.persona, self.topic, roster_names, snapshot, cancel, memories=memories
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
