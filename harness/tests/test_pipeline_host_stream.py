"""pipeline-host SSE streaming, model-free.

The fakes (stage, exchange, tokenizer) are duplicated from
``test_pipeline.py`` on purpose — local copies over reshaped shared helpers.
The tokenizer here adds ``last_segment``, the streaming-detokenizer surface
the SSE path drives; the non-stream ``text`` property matches, so the two
paths must produce identical text.
"""

from __future__ import annotations

import json
import threading

import httpx
import numpy as np

from party_line_harness.pipeline import host as host_mod


# ── fakes (duplicated from test_pipeline.py; see moduledoc) ─────────────────


class FakeStage:
    def __init__(self):
        self.shard = type("S", (), {"label": "stage 0/2 layers 0-5", "index": 0, "count": 2})()
        self.reset_calls: list[str] = []

    def reset(self, session):
        self.reset_calls.append(session)

    def step(self, session, *, tokens, hidden, want, sample, temperature, top_p):
        if want == "token":
            return "token", 123
        base = 0.0 if hidden is None else float(np.asarray(hidden).flat[0])
        return "hidden", np.array([[[base + 1.0]]], dtype=np.float32)


class _FakeExchange:
    """Records register/lease calls; returns canned catalog responses."""

    def __init__(self, lease_stages=None, expires_at=4102444800):
        self.lease_stages = lease_stages or []
        self.expires_at = expires_at
        self.auth: list = []
        self.lease_calls = 0

    def handler(self):
        from http.server import BaseHTTPRequestHandler

        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _reply(self, obj):
                body = json.dumps(obj).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0) or 0)
                payload = json.loads(self.rfile.read(n)) if n else {}
                outer.auth.append(self.headers.get("Authorization"))
                if self.path == "/api/pipelines/lease":
                    outer.lease_calls += 1
                    self._reply(
                        {"ok": True, "data": {
                            "model": payload["model"],
                            "expires_at": outer.expires_at,
                            "stages": outer.lease_stages,
                        }}
                    )
                else:
                    self._reply({"ok": False})

        return H


def _serve_exchange(ex):
    from http.server import ThreadingHTTPServer

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), ex.handler())
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, f"http://127.0.0.1:{httpd.server_address[1]}"


def _serve(host):
    from http.server import ThreadingHTTPServer

    from party_line_harness.pipeline.serve_shard import make_handler

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(host))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


class _StreamDetok:
    """A streaming detokenizer: ``last_segment`` yields the text grown since it
    was last read, like mlx's — so pieces concatenate to ``text`` exactly."""

    def __init__(self):
        self._toks: list[int] = []
        self._read = 0

    def reset(self):
        self._toks = []
        self._read = 0

    def add_token(self, t):
        self._toks.append(t)

    def finalize(self):
        pass

    @property
    def text(self):
        return " ".join(f"t{t}" for t in self._toks)

    @property
    def last_segment(self):
        full = self.text
        segment = full[self._read:]
        self._read = len(full)
        return segment


class FakeTokenizer:
    """Just enough tokenizer for the driver: template → ids, ids → text."""

    eos_token_id = 99

    def __init__(self):
        self.detokenizer = _StreamDetok()

    def apply_chat_template(self, messages, add_generation_prompt=True, **_kw):
        return list(range(1, len(messages) + 2))


# ── harness: one assembled fake pipeline behind a pipeline-host ─────────────


def _spin_up_host(stage=None):
    """Fake shard + fake exchange + PipelineChat + host server; returns the
    host's base url and a teardown closure."""
    from party_line_harness.pipeline.host import PipelineChat
    from party_line_harness.pipeline.serve_shard import ShardHost

    d0, p0 = _serve(ShardHost(stage or FakeStage(), "m", token="tA"))
    ex = _FakeExchange(
        lease_stages=[{"index": 0, "url": f"http://127.0.0.1:{p0}", "token": "tA"}]
    )
    dex, ex_url = _serve_exchange(ex)
    chat = PipelineChat(ex_url, "m", "pl-key", tokenizer=FakeTokenizer())
    httpd = host_mod.make_server(chat, "pipe", "sek")
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    def teardown():
        httpd.shutdown()
        chat.close()
        dex.shutdown()
        d0.shutdown()

    return f"http://127.0.0.1:{port}", teardown


def _sse_events(body: str) -> list[str]:
    return [
        block.removeprefix("data: ")
        for block in body.split("\n\n")
        if block.startswith("data: ")
    ]


# ── the tests ───────────────────────────────────────────────────────────────


def test_stream_chunks_join_to_the_non_stream_text():
    url, teardown = _spin_up_host()
    auth = {"Authorization": "Bearer sek"}
    body = {"messages": [{"role": "user", "content": "hi"}], "max_tokens": 3}
    try:
        plain = httpx.post(f"{url}/v1/chat/completions", json=body, headers=auth)
        assert plain.status_code == 200
        expected = plain.json()["choices"][0]["message"]["content"]
        assert expected == "t123 t123 t123"  # FakeStage's last stage always samples 123

        r = httpx.post(
            f"{url}/v1/chat/completions", json={**body, "stream": True}, headers=auth
        )
        assert r.status_code == 200
        assert r.headers["content-type"] == "text/event-stream"
        assert r.headers["cache-control"] == "no-cache"

        events = _sse_events(r.text)
        assert events[-1] == "[DONE]"
        chunks = [json.loads(e) for e in events[:-1]]

        for c in chunks:
            assert c["object"] == "chat.completion.chunk"
            assert c["model"] == "m"
            assert c["id"].startswith("chatcmpl-")
        # one id per stream, shared across its chunks
        assert len({c["id"] for c in chunks}) == 1

        *content, final = [c["choices"][0] for c in chunks]
        assert all(ch["finish_reason"] is None for ch in content)
        pieces = [ch["delta"]["content"] for ch in content]
        assert all(pieces)  # no empty deltas before the stop chunk
        assert "".join(pieces) == expected
        assert final["delta"] == {} and final["finish_reason"] == "stop"
    finally:
        teardown()


def test_stream_without_auth_is_still_a_json_401():
    url, teardown = _spin_up_host()
    try:
        r = httpx.post(
            f"{url}/v1/chat/completions",
            json={"messages": [{"role": "user", "content": "hi"}], "stream": True},
        )
        assert r.status_code == 401
        assert r.headers["content-type"] == "application/json"
        assert r.json() == {"error": "unauthorized"}
    finally:
        teardown()


def test_non_stream_requests_still_return_a_plain_completion():
    url, teardown = _spin_up_host()
    try:
        r = httpx.post(
            f"{url}/v1/chat/completions",
            json={"messages": [{"role": "user", "content": "hi"}], "max_tokens": 2},
            headers={"Authorization": "Bearer sek"},
        )
        assert r.status_code == 200
        assert r.headers["content-type"] == "application/json"
        out = r.json()
        assert out["object"] == "chat.completion"
        assert out["model"] == "m"
        assert out["choices"][0]["message"]["content"] == "t123 t123"
        assert out["choices"][0]["finish_reason"] == "stop"
    finally:
        teardown()


class _EosStage(FakeStage):
    """A shard whose first sampled token is the tokenizer's eos, so generation
    ends immediately with zero content — exercises the empty-stream path."""

    def step(self, session, *, want, **kw):
        if want == "token":
            return "token", FakeTokenizer.eos_token_id  # 99
        return super().step(session, want=want, **kw)


def test_empty_generation_still_yields_a_well_formed_stream():
    url, teardown = _spin_up_host(_EosStage())
    try:
        r = httpx.post(
            f"{url}/v1/chat/completions",
            json={"messages": [{"role": "user", "content": "hi"}], "stream": True},
            headers={"Authorization": "Bearer sek"},
        )
        assert r.status_code == 200
        assert r.headers["content-type"] == "text/event-stream"
        events = _sse_events(r.text)
        assert events[-1] == "[DONE]"
        chunks = [json.loads(e) for e in events[:-1]]
        # no content deltas — just the terminal stop chunk
        assert len(chunks) == 1
        assert chunks[0]["choices"][0]["delta"] == {}
        assert chunks[0]["choices"][0]["finish_reason"] == "stop"
    finally:
        teardown()


def test_stream_while_no_pipeline_is_a_json_503_not_sse():
    from party_line_harness.pipeline import host as host_mod

    class _Unavailable:
        model = "m"

        def chat(self, payload, on_text=None):
            raise host_mod.PipelineUnavailable("no complete pipeline for m")

    httpd = host_mod.make_server(_Unavailable(), "pipe", "sek")
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        # the error is raised before any chunk is written, so the stream branch
        # falls back to the normal JSON 503 (never opens an SSE response)
        r = httpx.post(
            f"http://127.0.0.1:{port}/v1/chat/completions",
            json={"messages": [{"role": "user", "content": "hi"}], "stream": True},
            headers={"Authorization": "Bearer sek"},
        )
        assert r.status_code == 503
        assert r.headers["content-type"] == "application/json"
    finally:
        httpd.shutdown()
