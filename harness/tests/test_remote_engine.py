"""RemoteEngine talks to a real serve-llm daemon (FakeEngine behind it).

Proves the round trip end to end over HTTP: a valid call returns text, a
wrong token degrades to None (never an exception), and a host that isn't
there degrades to None too.
"""

from __future__ import annotations

import asyncio
import threading

import pytest

from party_line_harness import serve_llm
from party_line_harness.inference.fake import FakeEngine
from party_line_harness.inference.remote import RemoteEngine
from party_line_harness.persona import Persona

TOKEN = "remote-token-xyz"

PERSONA = Persona(name="Nova", prime_directive="riff on the line.", interests=["moons"])


@pytest.fixture
def daemon():
    engine = FakeEngine(min_delay=0.0, max_delay=0.0, seed=2)
    host = serve_llm.LlmHost(engine, host_name="rig", model_id="fake", token=TOKEN)
    httpd = serve_llm.make_server(host, bind="127.0.0.1", port=0)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{httpd.server_address[1]}"
    try:
        yield base
    finally:
        httpd.shutdown()
        httpd.server_close()
        host.close()


async def _generate(engine: RemoteEngine, transcript=None):
    cancel = asyncio.Event()
    return await engine.generate(
        PERSONA, "the moon", ["Nova", "Bobby"], transcript or [], cancel
    )


@pytest.mark.asyncio
async def test_remote_generate_returns_text(daemon):
    engine = RemoteEngine(daemon, token=TOKEN, timeout=10.0)
    out = await _generate(engine)
    assert isinstance(out, str) and out


@pytest.mark.asyncio
async def test_remote_wrong_token_is_none(daemon):
    engine = RemoteEngine(daemon, token="wrong", timeout=10.0)
    assert await _generate(engine) is None


@pytest.mark.asyncio
async def test_remote_missing_token_is_none(daemon):
    engine = RemoteEngine(daemon, token=None, timeout=10.0)
    assert await _generate(engine) is None


@pytest.mark.asyncio
async def test_remote_dead_server_is_none():
    engine = RemoteEngine("http://127.0.0.1:1", token=TOKEN, timeout=0.25)
    assert await _generate(engine) is None


@pytest.mark.asyncio
async def test_remote_honours_cancel_before_call(daemon):
    engine = RemoteEngine(daemon, token=TOKEN, timeout=10.0)
    cancel = asyncio.Event()
    cancel.set()
    out = await engine.generate(PERSONA, "t", ["Nova"], [], cancel)
    assert out is None
