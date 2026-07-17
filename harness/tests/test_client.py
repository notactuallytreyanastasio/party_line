"""PersonaClient unit tests, model-free and in-process.

The ws side is a StubWs that only records `.send` frames; engines are
either FakeEngine (already cancellable) or tiny canned/raising stubs.
Memory is a recording fake in the shape of DeciduousMemory's surface.
No server, no sockets, no model.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import random

import httpx
import pytest

from party_line_harness import client as client_mod
from party_line_harness.client import FLUSH_EVERY, PersonaClient
from party_line_harness.inference.fake import FakeEngine
from party_line_harness.memory.episodic import episodic_notes
from party_line_harness.persona import Persona

SMOOTHIE = Persona(
    name="erowid smoothie",
    prime_directive="blend everything and report back.",
    interests=["raccoons", "kava"],
    chattiness=0.6,
)


class StubWs:
    """Just enough websocket: records every sent frame, parsed."""

    def __init__(self):
        self.sent: list[dict] = []

    async def send(self, frame: str) -> None:
        self.sent.append(json.loads(frame))


class CannedEngine:
    """Returns a fixed body instantly (or None)."""

    def __init__(self, body):
        self.body = body

    async def generate(
        self, persona, topic, roster_names, transcript, cancel, memories=None, on_delta=None
    ):
        return self.body


class RaisingEngine:
    async def generate(self, *args, **kwargs):
        raise RuntimeError("model fell over")


class RecordingMemory:
    """DeciduousMemory's surface, recording instead of talking HTTP."""

    def __init__(self, notes: list[str] | None = None):
        self.notes = notes or []
        self.observations: list[tuple[str, str | None]] = []
        self.ensure_calls = 0
        self.asked_about: list[str] = []

    def ensure_graph(self) -> bool:
        self.ensure_calls += 1
        return True

    def add_observation(self, title, description=None, branch=None):
        self.observations.append((title, branch))
        return len(self.observations)

    def recall_about(self, name, limit=5):
        self.asked_about.append(name)
        return self.notes


def make_client(engine, *, memory=None, typing_scale=0.0) -> PersonaClient:
    return PersonaClient(
        SMOOTHIE,
        engine,
        "http://127.0.0.1:4000",
        rng=random.Random(1),
        typing_scale=typing_scale,
        memory=memory,
    )


def wire_msg(sender: str, body: str, mentions=()) -> dict:
    return {
        "type": "message",
        "sender": {"name": sender, "kind": "human"},
        "body": body,
        "mentions": [{"name": m} for m in mentions],
    }


def participant(pid: str, name: str) -> dict:
    return {"participant_id": pid, "name": name, "kind": "human"}


def welcome_event(backlog: list[dict]) -> dict:
    return {
        "type": "welcome",
        "participant_id": "p-me",
        "room": {"id": "room-7", "topic": "everything"},
        "roster": [participant("p-me", "erowid smoothie")],
        "transcript": backlog,
    }


# ── grants and speaking ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_grant_revoked_aborts_inflight_generation():
    # the fake engine would "generate" for 30s; the revoke must abort it
    # immediately, and no speak frame may ever leave
    engine = FakeEngine(min_delay=30.0, max_delay=30.0, seed=1)
    client = make_client(engine)
    ws = StubWs()

    await client._handle(ws, {"type": "grant", "grant_id": "g1", "deadline_ms": 25_000})
    assert client._generation is not None and not client._generation.done()

    await client._handle(ws, {"type": "grant_revoked", "reason": "human_spoke"})
    await asyncio.wait_for(client._generation, timeout=5)
    assert ws.sent == []


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "engine",
    [RaisingEngine(), CannedEngine(None), CannedEngine("   \n")],
    ids=["engine-raises", "body-none", "body-whitespace"],
)
async def test_speak_forfeits_grant_silently(engine):
    client = make_client(engine)
    ws = StubWs()
    await client._speak(ws, {"grant_id": "g1", "deadline_ms": 50}, asyncio.Event())
    assert ws.sent == []


@pytest.mark.asyncio
async def test_typing_delay_is_capped_by_the_grant_deadline():
    # raw typing delay would be thousands of seconds (typing_scale=1000);
    # the deadline cap (60% of 50ms) must shrink it to nearly nothing
    client = make_client(CannedEngine("a" * 400), typing_scale=1000.0)
    ws = StubWs()
    loop = asyncio.get_running_loop()

    started = loop.time()
    await client._speak(ws, {"grant_id": "g1", "deadline_ms": 50}, asyncio.Event())

    assert loop.time() - started < 5.0
    assert ws.sent == [{"type": "speak", "grant_id": "g1", "body": "a" * 400}]


@pytest.mark.asyncio
async def test_cancel_during_typing_wait_suppresses_the_send():
    # instant engine + typing_scale=1.0 → at least the 1s base typing delay;
    # a revoke arriving mid-"typing" must swallow the message
    client = make_client(CannedEngine("plenty of words here"), typing_scale=1.0)
    ws = StubWs()
    cancel = asyncio.Event()

    task = asyncio.create_task(
        client._speak(ws, {"grant_id": "g1", "deadline_ms": 60_000}, cancel)
    )
    await asyncio.sleep(0.05)  # generation is instant; we are inside the typing wait
    cancel.set()
    await asyncio.wait_for(task, timeout=5)

    assert ws.sent == []


# ── boards compose path ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_compose_request_dispatches_and_sends_composed_frame():
    client = make_client(CannedEngine("  hot take: seeds are eggs  "))
    ws = StubWs()

    await client._handle(
        ws, {"type": "compose_request", "assignment_id": "a-1", "topic": "seed oils"}
    )
    deadline = asyncio.get_running_loop().time() + 5
    while not ws.sent and asyncio.get_running_loop().time() < deadline:
        await asyncio.sleep(0.01)

    assert ws.sent == [
        {"type": "composed", "assignment_id": "a-1", "body": "hot take: seeds are eggs"}
    ]


@pytest.mark.asyncio
async def test_ask_request_streams_deltas_then_a_final_answered():
    # zero-delay fake dribbles the answer out word by word
    engine = FakeEngine(min_delay=0.0, max_delay=0.0, seed=1)
    client = make_client(engine)
    ws = StubWs()

    await client._handle(ws, {"type": "ask_request", "ask_id": "ask-1", "prompt": "why knead"})

    deadline = asyncio.get_running_loop().time() + 5
    while not any(f["type"] == "answered" for f in ws.sent) and (
        asyncio.get_running_loop().time() < deadline
    ):
        await asyncio.sleep(0.01)

    deltas = [f for f in ws.sent if f["type"] == "answer_delta"]
    answered = [f for f in ws.sent if f["type"] == "answered"]

    assert answered, "an ask must end in an authoritative answered frame"
    assert len(deltas) >= 1, "the answer should have been streamed as deltas"
    # every frame carries the ask id, and the deltas reconstruct the body
    assert all(f["ask_id"] == "ask-1" for f in ws.sent)
    assert "".join(f["delta"] for f in deltas) == answered[0]["body"]


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "engine",
    [RaisingEngine(), CannedEngine(None), CannedEngine("")],
    ids=["engine-raises", "body-none", "body-empty"],
)
async def test_write_post_forfeits_assignment_silently(engine):
    client = make_client(engine)
    ws = StubWs()
    await client._write_post(ws, {"assignment_id": "a-1", "topic": "seed oils"})
    assert ws.sent == []


# ── presence ─────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_presence_joined_left_and_duplicate_join():
    client = make_client(CannedEngine(""))
    client.roster = [participant("p1", "bobdawg")]
    ws = StubWs()

    await client._handle(
        ws, {"type": "presence", "event": "joined", "participant": participant("p2", "priya")}
    )
    assert [p["participant_id"] for p in client.roster] == ["p1", "p2"]

    # a duplicate join must not double-add
    await client._handle(
        ws, {"type": "presence", "event": "joined", "participant": participant("p2", "priya")}
    )
    assert [p["participant_id"] for p in client.roster] == ["p1", "p2"]

    await client._handle(
        ws, {"type": "presence", "event": "left", "participant": participant("p1", "bobdawg")}
    )
    assert [p["participant_id"] for p in client.roster] == ["p2"]


# ── living memory ────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_welcome_backlog_is_never_summarized():
    memory = RecordingMemory()
    client = make_client(CannedEngine(""), memory=memory)
    ws = StubWs()
    backlog = [wire_msg("bobdawg", f"old business {i}") for i in range(3)]

    await client._handle(ws, welcome_event(backlog))

    assert client._flush_index == 3
    assert client.messages_since_flush == 0
    assert memory.ensure_calls == 1

    await client._flush_memory()  # window is empty: the backlog isn't ours
    assert memory.observations == []


@pytest.mark.asyncio
async def test_flush_every_heard_messages_writes_episodic_notes():
    memory = RecordingMemory()
    client = make_client(CannedEngine(""), memory=memory)
    ws = StubWs()
    await client._handle(ws, welcome_event([wire_msg("bobdawg", "backlog noise")]))

    heard = [wire_msg("bobdawg", "@erowid smoothie raccoons?", mentions=["Erowid Smoothie"])]
    heard += [wire_msg("priya", "the raccoons keep winning") for _ in range(FLUSH_EVERY - 1)]
    for event in heard:
        await client._handle(ws, event)

    expected = episodic_notes(client.persona, heard, client.persona.name)
    assert expected  # sanity: the summarizer produced notes for this window
    assert memory.observations == [(note, "room-7") for note in expected]
    assert client._flush_index == 1 + FLUSH_EVERY
    assert client.messages_since_flush == 0


@pytest.mark.asyncio
async def test_flush_memory_is_a_noop_without_memory():
    client = make_client(CannedEngine(""))
    client.transcript = [wire_msg("bobdawg", "hi")]
    await client._flush_memory()  # must not raise
    assert client._flush_index == 0  # nothing consumed


@pytest.mark.asyncio
async def test_flush_memory_never_flushes_the_same_window_twice():
    memory = RecordingMemory()
    client = make_client(CannedEngine(""), memory=memory)
    client.room_id = "room-7"
    client.transcript = [wire_msg("bobdawg", "hello there")]

    await client._flush_memory()
    first = list(memory.observations)
    assert first

    await client._flush_memory()  # the window already advanced past everything
    assert memory.observations == first
    assert client._flush_index == 1


# ── recall ───────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_recall_when_mentioned_case_insensitively_caps_at_three():
    memory = RecordingMemory(notes=[f"note {i}" for i in range(5)])
    client = make_client(CannedEngine(""), memory=memory)
    t = [wire_msg("bobdawg", "@Erowid Smoothie remember me?", mentions=["Erowid Smoothie"])]

    notes = await client._recall_for(t)

    assert notes == ["note 0", "note 1", "note 2"]
    assert memory.asked_about == ["bobdawg"]


@pytest.mark.asyncio
async def test_recall_ignores_mentions_of_someone_else():
    memory = RecordingMemory(notes=["note"])
    client = make_client(CannedEngine(""), memory=memory)
    t = [wire_msg("bobdawg", "@Horse Dentist look at this", mentions=["Horse Dentist"])]

    assert await client._recall_for(t) is None
    assert memory.asked_about == []


@pytest.mark.asyncio
async def test_recall_requires_a_sender_name():
    memory = RecordingMemory(notes=["note"])
    client = make_client(CannedEngine(""), memory=memory)
    last = {
        "type": "message",
        "sender": {},
        "body": "@erowid smoothie hi",
        "mentions": [{"name": "erowid smoothie"}],
    }
    assert await client._recall_for([last]) is None
    assert memory.asked_about == []


@pytest.mark.asyncio
async def test_recall_none_without_memory_or_transcript():
    no_memory = make_client(CannedEngine(""))
    t = [wire_msg("bobdawg", "@erowid smoothie hi", mentions=["erowid smoothie"])]
    assert await no_memory._recall_for(t) is None

    with_memory = make_client(CannedEngine(""), memory=RecordingMemory(notes=["note"]))
    assert await with_memory._recall_for([]) is None


# ── dialing ──────────────────────────────────────────────────────────────────


def test_ws_url_maps_http_to_ws():
    client = PersonaClient(SMOOTHIE, CannedEngine(""), "http://example.com:4000")
    assert client._ws_url("/ws/bot/websocket") == "ws://example.com:4000/ws/bot/websocket"


def test_ws_url_maps_https_to_wss():
    client = PersonaClient(SMOOTHIE, CannedEngine(""), "https://line.example:8443/")
    assert client._ws_url("/ws/bot/websocket") == "wss://line.example:8443/ws/bot/websocket"


@pytest.mark.asyncio
async def test_dial_failure_redials_instead_of_killing_the_persona(monkeypatch):
    monkeypatch.setattr(client_mod, "RECONNECT_DELAYS", [0.0])
    attempts = 0

    async def failing_session(self):
        nonlocal attempts
        attempts += 1
        raise httpx.ConnectError("dial refused")

    monkeypatch.setattr(PersonaClient, "_session", failing_session)
    client = make_client(CannedEngine(""))

    task = asyncio.create_task(client.run())
    try:
        deadline = asyncio.get_running_loop().time() + 5
        while attempts < 3 and asyncio.get_running_loop().time() < deadline:
            await asyncio.sleep(0.01)
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task

    assert attempts >= 3
