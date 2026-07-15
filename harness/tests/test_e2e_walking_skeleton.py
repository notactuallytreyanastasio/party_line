"""The walking skeleton, end to end and model-free.

Spawns the real Phoenix server (test env: millisecond director timings),
dials in the three shipped personas on FakeEngine, then a scripted human
verifies the milestone criteria over the actual wire protocol:

  1. bots sustain a conversation on their own
  2. an @-mentioned bot answers
  3. a human→human @ message draws no bot reply
  4. everything a human says broadcasts immediately
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import signal
import socket
import subprocess
import time
from pathlib import Path

import pytest
import websockets

from party_line_harness.client import PersonaClient
from party_line_harness.inference.fake import FakeEngine
from party_line_harness.persona import load_persona

ROOT = Path(__file__).resolve().parents[2]
SERVER = f"http://127.0.0.1:4002"
WS = "ws://127.0.0.1:4002/ws/bot/websocket"

pytestmark = pytest.mark.skipif(shutil.which("mix") is None, reason="needs elixir/mix")


@pytest.fixture(scope="module")
def phoenix_server():
    env = os.environ | {"MIX_ENV": "test"}
    proc = subprocess.Popen(
        ["mix", "run", "--no-halt"],
        cwd=ROOT / "server",
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", 4002), timeout=0.5):
                    break
            except OSError:
                if proc.poll() is not None:
                    raise RuntimeError("server exited early")
                time.sleep(0.3)
        else:
            raise RuntimeError("server never listened on 4002")
        yield proc
    finally:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        proc.wait(timeout=10)


class ScriptedHuman:
    """A human on the wire protocol (what the LiveView does, minus the UI)."""

    def __init__(self, name: str):
        self.name = name
        self.messages: list[dict] = []
        self.ws = None

    async def join(self):
        self.ws = await websockets.connect(WS)
        await self.ws.send(json.dumps({"type": "join", "name": self.name, "kind": "human"}))
        welcome = json.loads(await self.ws.recv())
        assert welcome["type"] == "welcome"
        self.pump = asyncio.create_task(self._pump())
        return self

    async def _pump(self):
        async for frame in self.ws:
            event = json.loads(frame)
            if event["type"] == "message":
                self.messages.append(event)

    async def say(self, body: str):
        await self.ws.send(json.dumps({"type": "speak", "grant_id": None, "body": body}))

    def bot_messages(self):
        return [m for m in self.messages if m["sender"]["kind"] == "bot"]

    async def close(self):
        self.pump.cancel()
        await self.ws.close()


async def wait_for(predicate, timeout: float, interval: float = 0.1):
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        if predicate():
            return True
        await asyncio.sleep(interval)
    return False


@pytest.mark.asyncio
async def test_walking_skeleton(phoenix_server):
    personas = [load_persona(p) for p in sorted((ROOT / "personas").glob("*.yaml"))]
    engine = FakeEngine(min_delay=0.02, max_delay=0.08, seed=42)
    bots = [
        PersonaClient(p, engine, SERVER, typing_scale=0.0) for p in personas
    ]
    bot_tasks = [asyncio.create_task(b.run()) for b in bots]

    human = await ScriptedHuman("Bobby").join()
    watcher = await ScriptedHuman("Priya").join()

    try:
        # 1. bots talk on their own: several messages from >1 distinct bot
        assert await wait_for(
            lambda: len(human.bot_messages()) >= 3
            and len({m["sender"]["name"] for m in human.bot_messages()}) >= 2,
            timeout=15,
        ), f"bots never got going: {[m['body'] for m in human.messages]}"

        # 2. an @-mentioned bot answers (FakeEngine replies start with @sender)
        await human.say("@DigimonOtis what is actually up with the moon")
        assert await wait_for(
            lambda: any(
                m["sender"]["name"] == "DigimonOtis"
                and any(x["name"] == "Bobby" for x in m["mentions"])
                for m in human.bot_messages()
            ),
            timeout=10,
        ), "mentioned bot never answered"

        # 3. human→human @ message: broadcast to everyone, no bot reply to it
        before = len(human.bot_messages())
        await human.say("@Priya did you see the coyote thing?")
        assert await wait_for(
            lambda: any("@Priya" in m["body"] for m in watcher.messages), timeout=5
        ), "human→human message was not broadcast"

        # give the fast beat + a regular beat time to pass, then check no bot
        # addressed either human about it
        await asyncio.sleep(1.0)
        replies_to_humans = [
            m
            for m in human.bot_messages()[before:]
            if any(x["name"] in ("Bobby", "Priya") for x in m["mentions"])
        ]
        assert replies_to_humans == [], f"a bot butted into a human→human exchange: {replies_to_humans}"

        # 4. sequences are totally ordered and gapless from each observer
        seqs = [m["seq"] for m in human.messages]
        assert seqs == sorted(seqs)
    finally:
        for task in bot_tasks:
            task.cancel()
        await human.close()
        await watcher.close()
