"""serve-llm: lend your local model to the party line.

A little piece of code someone runs to host their own model for the
exchange. It:

  * serves a tiny HTTP endpoint (``POST /v1/generate``, ``GET /healthz``)
    that runs the local engine behind a bearer token;
  * exposes that endpoint on the tailnet with ``tailscale serve`` (or the
    whole internet with ``--funnel``), falling back to localhost-only if
    tailscale isn't around;
  * registers a catalog entry with the party-line server and heartbeats
    it, so the room can list the host — WITHOUT ever handing the server
    the bearer token (token distribution is out-of-band, host to friends).

Everything is best-effort around the edges: an unreachable catalog, a
missing tailscale binary, a flaky heartbeat — none of these crash the
daemon. It keeps serving locally until the operator stops it (Ctrl-C /
SIGTERM), at which point it deregisters, tears down the tailscale share,
and exits 0.

Engine access is serialized through a single dedicated event-loop thread:
the engine's own ``asyncio.Lock`` only ever binds to that one loop, so
concurrent HTTP handler threads queue behind it exactly as the persona
clients do in-process.
"""

from __future__ import annotations

import argparse
import asyncio
import dataclasses
import json
import logging
import secrets
import shutil
import signal
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import httpx

from .inference.fake import FakeEngine
from .persona import Persona

log = logging.getLogger("party_line")

DEFAULT_LLM_PORT = 8377
DEFAULT_NAME = "anonymous exchange"

_PERSONA_FIELDS = {f.name for f in dataclasses.fields(Persona)}


def _persona_from_dict(raw: Any) -> Persona:
    """Rebuild a Persona from the wire dict, ignoring unknown keys."""
    if not isinstance(raw, dict):
        raise ValueError("persona must be a JSON object")
    kwargs = {k: v for k, v in raw.items() if k in _PERSONA_FIELDS}
    try:
        return Persona(**kwargs)  # __post_init__ raises ValueError; missing args raise TypeError
    except TypeError as exc:
        raise ValueError(str(exc)) from exc


# ── the host: engine behind a serialized event loop ─────────────────────────


class LlmHost:
    """Owns the engine and a private event-loop thread it runs on.

    ``generate`` is callable from any thread (each HTTP handler runs in its
    own): it hands the coroutine to the one loop, where the engine's lock
    lives, and blocks for the result.
    """

    def __init__(self, engine: Any, host_name: str, model_id: str, token: str):
        self.engine = engine
        self.host_name = host_name
        self.model_id = model_id
        self.token = token
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._loop.run_forever, daemon=True)
        self._thread.start()

    def _submit(self, coro) -> Any:
        return asyncio.run_coroutine_threadsafe(coro, self._loop).result()

    def warmup(self) -> float | None:
        warm = getattr(self.engine, "warmup", None)
        if warm is None:
            return None
        return self._submit(warm())

    def generate(self, payload: Any) -> str | None:
        """Run one generation for a /v1/generate body. Raises ValueError on a
        malformed body; other engine errors propagate to the caller."""
        if not isinstance(payload, dict):
            raise ValueError("body must be a JSON object")
        persona = _persona_from_dict(payload.get("persona"))
        topic = payload.get("topic") or ""
        roster = payload.get("roster_names") or []
        transcript = payload.get("transcript") or []
        memories = payload.get("memories")
        return self._submit(self._generate(persona, topic, roster, transcript, memories))

    async def _generate(
        self,
        persona: Persona,
        topic: str,
        roster: list[str],
        transcript: list[dict[str, Any]],
        memories: list[str] | None,
    ) -> str | None:
        cancel = asyncio.Event()  # created on the loop; the host never cancels
        return await self.engine.generate(
            persona, topic, roster, transcript, cancel, memories=memories
        )

    def close(self) -> None:
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=5)


# ── HTTP surface ────────────────────────────────────────────────────────────


def make_handler(host: LlmHost) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):  # silence the default access log
            pass

        def _send(self, status: int, payload: dict) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _authed(self) -> bool:
            got = self.headers.get("Authorization", "")
            return secrets.compare_digest(got, f"Bearer {host.token}")

        def _read_json(self) -> Any:
            length = int(self.headers.get("Content-Length", 0) or 0)
            raw = self.rfile.read(length) if length else b""
            return json.loads(raw)  # raises on malformed / empty

        def do_GET(self):
            if self.path == "/healthz":
                self._send(
                    200,
                    {"ok": True, "model": host.model_id, "host_name": host.host_name},
                )
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/v1/generate":
                return self._send(404, {"error": "not found"})
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            try:
                payload = self._read_json()
            except (json.JSONDecodeError, ValueError):
                return self._send(400, {"error": "malformed json"})
            try:
                text = host.generate(payload)
            except ValueError as exc:
                return self._send(400, {"error": str(exc)})
            except Exception:
                log.exception("generation failed")
                return self._send(500, {"error": "generation failed"})
            self._send(200, {"text": text})

    return Handler


def make_server(host: LlmHost, bind: str = "127.0.0.1", port: int = DEFAULT_LLM_PORT) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((bind, port), make_handler(host))


# ── catalog registration ────────────────────────────────────────────────────


class Catalog:
    """The party-line server's host registry. Never sees the bearer token."""

    def __init__(
        self,
        server_url: str,
        name: str,
        url: str,
        model: str,
        *,
        requires_token: bool = True,
        timeout: float = 10.0,
    ):
        self.server_url = server_url.rstrip("/")
        self.name = name
        self.url = url
        self.model = model
        self.requires_token = requires_token
        self.timeout = timeout
        self.host_id: Any = None
        self.ttl_seconds: int = 60

    def register(self) -> bool:
        payload = {
            "name": self.name,
            "url": self.url,
            "model": self.model,
            "requires_token": self.requires_token,
        }
        try:
            resp = httpx.post(
                f"{self.server_url}/api/hosts/register", json=payload, timeout=self.timeout
            )
            resp.raise_for_status()
            data = (resp.json() or {}).get("data") or {}
        except (httpx.HTTPError, ValueError) as exc:
            log.warning("catalog register failed: %s", exc)
            return False
        self.host_id = data.get("id")
        ttl = data.get("ttl_seconds")
        if isinstance(ttl, (int, float)) and ttl > 0:
            self.ttl_seconds = int(ttl)
        if self.host_id is None:
            return False
        log.info("registered with catalog as host %s (ttl %ss)", self.host_id, self.ttl_seconds)
        return True

    def heartbeat(self) -> bool:
        """Refresh the catalog entry; re-register if we were never registered
        or the server has forgotten us (retry-on-every-interval contract)."""
        if self.host_id is None:
            return self.register()
        try:
            resp = httpx.post(
                f"{self.server_url}/api/hosts/{self.host_id}/heartbeat", timeout=self.timeout
            )
            resp.raise_for_status()
        except (httpx.HTTPError, ValueError) as exc:
            log.warning("catalog heartbeat failed: %s; will re-register", exc)
            self.host_id = None
            return False
        return True

    def deregister(self) -> None:
        if self.host_id is None:
            return
        try:
            httpx.delete(f"{self.server_url}/api/hosts/{self.host_id}", timeout=self.timeout)
            log.info("deregistered host %s from catalog", self.host_id)
        except httpx.HTTPError as exc:  # pragma: no cover - best-effort teardown
            log.warning("catalog deregister failed: %s", exc)
        self.host_id = None


def _heartbeat_loop(catalog: Catalog, stop: threading.Event) -> None:
    while not stop.is_set():
        interval = max(1.0, catalog.ttl_seconds / 3)
        if stop.wait(interval):
            break
        catalog.heartbeat()


# ── tailscale ───────────────────────────────────────────────────────────────


def tailscale_available() -> bool:
    return shutil.which("tailscale") is not None


def tailscale_dns_name() -> str | None:
    """Self.DNSName from ``tailscale status --json``, trailing dot stripped."""
    try:
        proc = subprocess.run(
            ["tailscale", "status", "--json"], capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        return None
    dns = ((data or {}).get("Self") or {}).get("DNSName") or ""
    return dns.rstrip(".") or None


def start_tailscale(port: int, *, funnel: bool = False) -> str | None:
    """Expose ``port`` on the tailnet (or the internet with funnel). Returns
    the public https URL, or None if tailscale is missing/errors."""
    if not tailscale_available():
        return None
    verb = "funnel" if funnel else "serve"
    try:
        proc = subprocess.run(
            ["tailscale", verb, "--bg", str(port)], capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log.warning("tailscale %s failed: %s", verb, exc)
        return None
    if proc.returncode != 0:
        log.warning("tailscale %s failed: %s", verb, (proc.stderr or "").strip())
        return None
    dns = tailscale_dns_name()
    if not dns:
        return None
    return f"https://{dns}"


def stop_tailscale(*, funnel: bool = False) -> None:
    if not tailscale_available():
        return
    verb = "funnel" if funnel else "serve"
    try:
        subprocess.run(
            ["tailscale", verb, "--bg", "off"], capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.SubprocessError) as exc:  # pragma: no cover
        log.warning("tailscale %s off failed: %s", verb, exc)


def resolve_public_url(
    port: int, *, funnel: bool = False, no_tailscale: bool = False
) -> tuple[str, bool]:
    """(url, used_tailscale). Falls back to localhost if tailscale is off or
    unavailable — never raises."""
    local = f"http://127.0.0.1:{port}"
    if no_tailscale:
        return local, False
    url = start_tailscale(port, funnel=funnel)
    if url is None:
        log.warning("tailscale unavailable; serving locally only at %s", local)
        return local, False
    return url, True


# ── CLI / daemon ────────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="party-line-harness serve-llm",
        description="host your local model on the party line until you stop it",
    )
    parser.add_argument("--server", default="http://127.0.0.1:4000", help="party-line catalog server")
    parser.add_argument("--name", default=DEFAULT_NAME, help="how the host shows up in the catalog")
    parser.add_argument("--llm-port", type=int, default=DEFAULT_LLM_PORT)
    parser.add_argument("--llm-bind", default="127.0.0.1", help="local bind address (tailscale proxies to it)")
    parser.add_argument("--llm-token", default=None, help="bearer token (auto-generated if omitted)")
    parser.add_argument("--engine", choices=["mlx", "fake"], default="mlx")
    parser.add_argument("--model", default=None, help="mlx-community model id override")
    parser.add_argument("--fake-delay", type=float, default=3.0, help="fake engine max latency (s)")
    parser.add_argument("--no-tailscale", action="store_true", help="serve localhost only")
    parser.add_argument("--funnel", action="store_true", help="expose to the public internet, not just the tailnet")
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser


def _build_engine(args: argparse.Namespace) -> tuple[Any, str]:
    if args.engine == "fake":
        return FakeEngine(min_delay=min(1.0, args.fake_delay), max_delay=args.fake_delay), "fake"
    from .inference.engine import DEFAULT_MODEL, MlxEngine

    engine = MlxEngine(args.model or DEFAULT_MODEL)
    return engine, engine.model_id


def _announce_token(token: str, generated: bool) -> None:
    banner = "=" * 60
    origin = "auto-generated" if generated else "from --llm-token"
    log.info("\n%s\n  ACCESS TOKEN (%s) — share it with your friends,\n"
             "  NOT with the catalog server:\n\n      %s\n\n"
             "  Friends dial in with:  --engine remote --remote-token <token>\n%s",
             banner, origin, token, banner)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(message)s",
        datefmt="%H:%M:%S",
    )

    engine, model_id = _build_engine(args)
    token = args.llm_token or secrets.token_urlsafe(24)
    _announce_token(token, generated=args.llm_token is None)

    host = LlmHost(engine, host_name=args.name, model_id=model_id, token=token)
    if args.engine != "fake":
        log.info("loading %s (first run downloads the weights)…", model_id)
        tok_s = host.warmup()
        if tok_s:
            log.info("model warm: %.1f tok/s", tok_s)

    httpd = make_server(host, bind=args.llm_bind, port=args.llm_port)
    bound_port = httpd.server_address[1]
    server_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    server_thread.start()
    log.info("serving /v1/generate on %s:%d", args.llm_bind, bound_port)

    public_url, used_tailscale = resolve_public_url(
        bound_port, funnel=args.funnel, no_tailscale=args.no_tailscale
    )
    log.info("public URL: %s", public_url)

    catalog = Catalog(args.server, args.name, public_url, model_id, requires_token=True)
    catalog.register()  # if it fails, the heartbeat loop keeps retrying

    stop = threading.Event()
    heartbeat = threading.Thread(target=_heartbeat_loop, args=(catalog, stop), daemon=True)
    heartbeat.start()

    stopping = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stopping.set())
    signal.signal(signal.SIGTERM, lambda *_: stopping.set())
    log.info("on the line. Ctrl-C to stop and take the model home.")
    stopping.wait()

    log.info("shutting down…")
    stop.set()
    catalog.deregister()
    if used_tailscale:
        stop_tailscale(funnel=args.funnel)
    httpd.shutdown()
    host.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
