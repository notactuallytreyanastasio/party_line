"""serve-llm daemon: HTTP surface, auth, catalog protocol, tailscale URL.

The daemon is exercised in-process — a real ThreadingHTTPServer on port 0
behind a FakeEngine, a stdlib stub standing in for the catalog, and
monkeypatched ``shutil.which`` / ``subprocess.run`` for tailscale. No
model, no real tailscale, no real party-line server.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx
import pytest

from party_line_harness import serve_llm
from party_line_harness.inference.fake import FakeEngine

TOKEN = "test-token-123"

PERSONA = {
    "name": "Nova",
    "prime_directive": "you riff on whatever's on the line.",
    "voice": "dry",
    "interests": ["moons"],
    "chattiness": 0.6,
    "temperature": 0.8,
    "max_tokens": 180,
}


def _payload(transcript=None):
    return {
        "persona": PERSONA,
        "topic": "the moon",
        "roster_names": ["Nova", "Bobby"],
        "transcript": transcript or [],
        "memories": None,
    }


@pytest.fixture
def daemon():
    engine = FakeEngine(min_delay=0.0, max_delay=0.0, seed=1)
    host = serve_llm.LlmHost(engine, host_name="rig-7", model_id="fake", token=TOKEN)
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


class _RaisingEngine:
    async def generate(self, *args, **kwargs):
        raise RuntimeError("engine exploded")


@pytest.fixture
def raising_daemon():
    host = serve_llm.LlmHost(_RaisingEngine(), host_name="rig-7", model_id="fake", token=TOKEN)
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


def _auth(token=TOKEN):
    return {"Authorization": f"Bearer {token}"}


# ── HTTP surface ────────────────────────────────────────────────────────────


def test_healthz_reports_model_and_host(daemon):
    resp = httpx.get(f"{daemon}/healthz")
    assert resp.status_code == 200
    body = resp.json()
    assert body == {"ok": True, "model": "fake", "host_name": "rig-7"}


def test_generate_returns_text_for_valid_payload(daemon):
    resp = httpx.post(f"{daemon}/v1/generate", json=_payload(), headers=_auth())
    assert resp.status_code == 200
    text = resp.json()["text"]
    assert isinstance(text, str) and text  # FakeEngine opener on empty transcript


def test_generate_requires_token(daemon):
    resp = httpx.post(f"{daemon}/v1/generate", json=_payload())
    assert resp.status_code == 401


def test_generate_rejects_wrong_token(daemon):
    resp = httpx.post(f"{daemon}/v1/generate", json=_payload(), headers=_auth("nope"))
    assert resp.status_code == 401


def test_generate_malformed_json_is_400(daemon):
    resp = httpx.post(
        f"{daemon}/v1/generate",
        content=b"{not json",
        headers={**_auth(), "Content-Type": "application/json"},
    )
    assert resp.status_code == 400


def test_generate_bad_persona_is_400(daemon):
    bad = _payload()
    bad["persona"] = {"voice": "dry"}  # missing name / prime_directive
    resp = httpx.post(f"{daemon}/v1/generate", json=bad, headers=_auth())
    assert resp.status_code == 400


def test_generate_non_object_body_is_400(daemon):
    resp = httpx.post(f"{daemon}/v1/generate", json=["not", "an", "object"], headers=_auth())
    assert resp.status_code == 400
    assert resp.json() == {"error": "body must be a JSON object"}


def test_generate_engine_failure_is_500(raising_daemon):
    resp = httpx.post(f"{raising_daemon}/v1/generate", json=_payload(), headers=_auth())
    assert resp.status_code == 500
    assert resp.json() == {"error": "generation failed"}


def test_unknown_post_path_is_404_regardless_of_auth(daemon):
    resp = httpx.post(f"{daemon}/v1/nope", json={})  # no auth header on purpose
    assert resp.status_code == 404
    assert resp.json() == {"error": "not found"}


def test_unknown_get_path_is_404(daemon):
    resp = httpx.get(f"{daemon}/nope", headers=_auth())
    assert resp.status_code == 404
    assert resp.json() == {"error": "not found"}


# ── catalog protocol ────────────────────────────────────────────────────────


class _CatalogHandler(BaseHTTPRequestHandler):
    calls: list[dict] = []
    fail_heartbeat: bool = False

    def log_message(self, *args):
        pass

    def _read(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if not length:
            return None
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            return None

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _record(self, method):
        type(self).calls.append(
            {"method": method, "path": self.path, "body": self._read()}
        )

    def do_POST(self):
        self._record("POST")
        if self.path == "/api/hosts/register":
            self._send(201, {"data": {"id": "host-42", "ttl_seconds": 30}})
        elif type(self).fail_heartbeat:
            self._send(500, {"error": "boom"})
        else:  # heartbeat
            self._send(200, {"data": {"ok": True}})

    def do_DELETE(self):
        self._record("DELETE")
        self._send(200, {"data": {"ok": True}})


@pytest.fixture
def catalog_stub():
    _CatalogHandler.calls = []
    _CatalogHandler.fail_heartbeat = False
    server = ThreadingHTTPServer(("127.0.0.1", 0), _CatalogHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    try:
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        server.server_close()


def test_catalog_register_heartbeat_deregister_sequence(catalog_stub):
    cat = serve_llm.Catalog(
        catalog_stub, name="rig-7", url="https://rig-7.ts.net", model="fake"
    )

    assert cat.register() is True
    assert cat.host_id == "host-42"
    assert cat.ttl_seconds == 30  # picked up from the envelope

    assert cat.heartbeat() is True
    cat.deregister()
    assert cat.host_id is None

    calls = _CatalogHandler.calls
    assert [(c["method"], c["path"]) for c in calls] == [
        ("POST", "/api/hosts/register"),
        ("POST", "/api/hosts/host-42/heartbeat"),
        ("DELETE", "/api/hosts/host-42"),
    ]
    # the token is NEVER shipped to the catalog — only url/name/model
    reg = calls[0]["body"]
    assert reg == {
        "name": "rig-7",
        "url": "https://rig-7.ts.net",
        "model": "fake",
        "requires_token": True,
    }
    assert "token" not in reg


def test_catalog_heartbeat_reregisters_when_unregistered(catalog_stub):
    cat = serve_llm.Catalog(catalog_stub, name="rig-7", url="https://x", model="fake")
    # never registered → heartbeat should register
    assert cat.heartbeat() is True
    assert cat.host_id == "host-42"
    assert _CatalogHandler.calls[0]["path"] == "/api/hosts/register"


def test_catalog_unreachable_server_never_raises():
    cat = serve_llm.Catalog("http://127.0.0.1:1", name="x", url="y", model="z", timeout=0.25)
    assert cat.register() is False
    assert cat.heartbeat() is False  # host_id still None → tries register → False
    cat.deregister()  # no-op, no raise


def test_heartbeat_500_clears_host_id_then_next_heartbeat_reregisters(catalog_stub):
    cat = serve_llm.Catalog(catalog_stub, name="rig-7", url="https://x", model="fake")
    assert cat.register() is True

    _CatalogHandler.fail_heartbeat = True
    assert cat.heartbeat() is False
    assert cat.host_id is None  # forgotten: the next interval must re-register

    _CatalogHandler.fail_heartbeat = False
    assert cat.heartbeat() is True
    assert cat.host_id == "host-42"

    assert [(c["method"], c["path"]) for c in _CatalogHandler.calls] == [
        ("POST", "/api/hosts/register"),
        ("POST", "/api/hosts/host-42/heartbeat"),
        ("POST", "/api/hosts/register"),
    ]


# ── heartbeat loop (scripted stop event: zero wall-clock waiting) ────────────


class _ScriptedStop:
    """Duck-typed stop event: times out `beats` times, then reads as set."""

    def __init__(self, beats: int):
        self.beats = beats
        self.intervals: list[float] = []

    def is_set(self) -> bool:
        return len(self.intervals) > self.beats

    def wait(self, interval: float) -> bool:
        self.intervals.append(interval)
        return len(self.intervals) > self.beats


class _CountingCatalog:
    def __init__(self, ttl_seconds: int):
        self.ttl_seconds = ttl_seconds
        self.beats = 0

    def heartbeat(self) -> bool:
        self.beats += 1
        return True


def test_heartbeat_loop_paces_at_a_third_of_ttl_and_stops():
    stop = _ScriptedStop(beats=2)
    catalog = _CountingCatalog(ttl_seconds=30)
    serve_llm._heartbeat_loop(catalog, stop)  # returns as soon as stop fires
    assert catalog.beats == 2
    assert stop.intervals == [10.0, 10.0, 10.0]


def test_heartbeat_loop_floors_the_interval_at_one_second():
    stop = _ScriptedStop(beats=1)
    catalog = _CountingCatalog(ttl_seconds=1)
    serve_llm._heartbeat_loop(catalog, stop)
    assert stop.intervals == [1.0, 1.0]


# ── tailscale (no real tailscale invoked) ───────────────────────────────────


class _FakeProc:
    def __init__(self, stdout="", returncode=0, stderr=""):
        self.stdout = stdout
        self.returncode = returncode
        self.stderr = stderr


def test_dns_name_strips_trailing_dot(monkeypatch):
    status = {"Self": {"DNSName": "rig-7.tail1234.ts.net."}}
    monkeypatch.setattr(serve_llm.shutil, "which", lambda _: "/usr/bin/tailscale")
    monkeypatch.setattr(
        serve_llm.subprocess, "run", lambda *a, **k: _FakeProc(json.dumps(status))
    )
    assert serve_llm.tailscale_dns_name() == "rig-7.tail1234.ts.net"


def test_resolve_public_url_uses_tailscale_dns(monkeypatch):
    status = {"Self": {"DNSName": "rig-7.tail1234.ts.net."}}

    def fake_run(cmd, *a, **k):
        if "status" in cmd:
            return _FakeProc(json.dumps(status))
        return _FakeProc("")  # serve --bg

    monkeypatch.setattr(serve_llm.shutil, "which", lambda _: "/usr/bin/tailscale")
    monkeypatch.setattr(serve_llm.subprocess, "run", fake_run)

    url, used = serve_llm.resolve_public_url(8377, funnel=False, no_tailscale=False)
    assert url == "https://rig-7.tail1234.ts.net"
    assert used is True


def test_resolve_public_url_falls_back_when_tailscale_missing(monkeypatch):
    monkeypatch.setattr(serve_llm.shutil, "which", lambda _: None)
    url, used = serve_llm.resolve_public_url(8377, no_tailscale=False)
    assert url == "http://127.0.0.1:8377"
    assert used is False


def test_resolve_public_url_respects_no_tailscale(monkeypatch):
    # even with tailscale present, --no-tailscale means localhost only
    monkeypatch.setattr(serve_llm.shutil, "which", lambda _: "/usr/bin/tailscale")
    called = False

    def fake_run(*a, **k):
        nonlocal called
        called = True
        return _FakeProc("")

    monkeypatch.setattr(serve_llm.subprocess, "run", fake_run)
    url, used = serve_llm.resolve_public_url(9000, no_tailscale=True)
    assert url == "http://127.0.0.1:9000"
    assert used is False
    assert called is False  # never shells out to tailscale


def test_start_tailscale_returns_none_on_nonzero_exit(monkeypatch):
    monkeypatch.setattr(serve_llm.shutil, "which", lambda _: "/usr/bin/tailscale")
    monkeypatch.setattr(
        serve_llm.subprocess,
        "run",
        lambda *a, **k: _FakeProc("", returncode=1, stderr="serve broke"),
    )
    assert serve_llm.start_tailscale(8377) is None


def test_start_tailscale_returns_none_when_dns_name_empty(monkeypatch):
    status = {"Self": {"DNSName": ""}}

    def fake_run(cmd, *a, **k):
        if "status" in cmd:
            return _FakeProc(json.dumps(status))
        return _FakeProc("")  # serve --bg succeeds

    monkeypatch.setattr(serve_llm.shutil, "which", lambda _: "/usr/bin/tailscale")
    monkeypatch.setattr(serve_llm.subprocess, "run", fake_run)
    assert serve_llm.start_tailscale(8377) is None


# ── LlmHost.warmup ──────────────────────────────────────────────────────────


class _WarmableEngine:
    async def warmup(self):
        return 42.5

    async def generate(self, *args, **kwargs):  # pragma: no cover - unused
        return "unused"


def test_warmup_is_none_when_engine_has_no_warmup():
    host = serve_llm.LlmHost(
        FakeEngine(min_delay=0.0, max_delay=0.0, seed=1),
        host_name="rig-7",
        model_id="fake",
        token=TOKEN,
    )
    try:
        assert host.warmup() is None
    finally:
        host.close()


def test_warmup_forwards_the_engine_result():
    host = serve_llm.LlmHost(_WarmableEngine(), host_name="rig-7", model_id="fake", token=TOKEN)
    try:
        assert host.warmup() == 42.5
    finally:
        host.close()
