"""serve-shard: lend one slice of a model to a pipeline.

Loads a single shard (``--stage i/n``) and serves its partial forward over
HTTP, behind an ``Authorization: Bearer`` gate — a driver presents either the
raw shard secret (hand-wired ``--stage`` setups) or an exchange-minted lease
token (``_lease_ok``), relays hidden states through the ordered shards, and the
last shard samples. Two of these on two machines (``--stage 0/2`` and
``--stage 1/2``, same ``--model``) are a two-machine model.

The wire is the binary frame in ``wire.py``: ``POST /pipeline/forward`` takes a
header + optional hidden tensor and returns a hidden tensor or a token;
``POST /pipeline/reset`` drops a session's caches; ``GET /healthz`` is open.

MLX wants one generation at a time, so every model step is funneled through a
single worker thread (``_submit``) — which also pins the Metal streams to one
thread. With ``--server``/``--exchange-key`` the shard also registers itself
with the exchange's pipeline catalog (``ShardCatalog``) so it can be assembled
and leased; without a key it just serves locally.
"""

from __future__ import annotations

import argparse
import logging
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from ..serve_llm import _heartbeat_loop, resolve_public_url, stop_tailscale
from . import wire
from .stage import PipelineStage, ShardOverloaded

log = logging.getLogger("party_line")

DEFAULT_SHARD_PORT = 8378
# a prefill hidden state is [1, seq, hidden] float32 — tens of MB for a long
# prompt on a wide model; give the body a generous ceiling, not a prompt-sized one.
MAX_FRAME = 512_000_000


class ShardHost:
    """A loaded shard behind a single dedicated MLX worker thread.

    MLX's Metal streams are bound to the thread that created them, and
    ``ThreadingHTTPServer`` runs every request on a fresh thread — calling into
    the model from a handler thread dies with "no Stream(gpu, N) in current
    thread" (the live run caught this; unit tests with fake stages never
    could). So ALL model work — the load and every step — funnels through one
    worker thread, which also serializes Metal exactly as ``serve-llm``'s
    ``LlmHost`` does with its private event loop.
    """

    def __init__(self, stage: PipelineStage, model_id: str, token: str):
        self.stage = stage
        self.model_id = model_id
        self.token = token
        # per-session forward counters: the driver's request id is the session
        # id, so this shard's log lines correlate with every other machine's.
        # Guarded by a lock — bookkeeping runs on the (threaded) handler, not
        # the single MLX worker, so concurrent forwards race the plain dict.
        self._sessions: dict[str, int] = {}
        self._sessions_lock = threading.Lock()
        from concurrent.futures import ThreadPoolExecutor

        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx-shard")

    @classmethod
    def load(cls, model_id: str, stage_spec: str, *, token: str) -> "ShardHost":
        """Build the host with its shard loaded ON the worker thread, so every
        Metal stream the model touches lives where the steps will run."""
        host = cls.__new__(cls)
        host.model_id = model_id
        host.token = token
        host._sessions = {}
        host._sessions_lock = threading.Lock()
        from concurrent.futures import ThreadPoolExecutor

        host._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx-shard")
        host.stage = host._submit(PipelineStage.load, model_id, stage_spec)
        return host

    def _submit(self, fn, *args, **kwargs):
        return self._pool.submit(fn, *args, **kwargs).result()

    def authorized(self, presented: str) -> bool:
        """The raw secret (manual ``--stage`` wiring by the operator), or a
        short-lived HMAC lease token minted by the exchange — which holds our
        secret privately and derives tokens from it, so leasing never hands the
        secret itself to a caller."""
        if secrets.compare_digest(presented, self.token):
            return True
        return self._lease_ok(presented)

    def _lease_ok(self, presented: str) -> bool:
        """Verify ``plsl1.<expiry>.<base64url hmac>`` — the MAC is HMAC-SHA256
        over ``pl-shard-lease|v1|<model>|<count>|<index>|<expiry>`` keyed by our
        secret. Mirrors ``PartyLine.Pipelines.lease_token/5`` byte for byte (a
        shared golden vector in both test suites keeps them honest)."""
        import base64
        import hashlib
        import hmac
        import time

        parts = presented.split(".")
        if len(parts) != 3 or parts[0] != "plsl1":
            return False
        try:
            expiry = int(parts[1])
        except ValueError:
            return False
        if time.time() > expiry:
            return False
        shard = self.stage.shard
        payload = f"pl-shard-lease|v1|{self.model_id}|{shard.count}|{shard.index}|{expiry}"
        want = (
            base64.urlsafe_b64encode(
                hmac.new(self.token.encode(), payload.encode(), hashlib.sha256).digest()
            )
            .rstrip(b"=")
            .decode()
        )
        return hmac.compare_digest(want, parts[2])

    def forward(self, header: dict[str, Any], tensor) -> bytes:
        import time

        session = str(header.get("session", "s0"))
        want = header.get("want", "hidden")
        tokens = header.get("tokens")
        started = time.monotonic()
        kind, payload = self._submit(
            self.stage.step,
            session,
            tokens=tokens,
            hidden=tensor,
            want=want,
            sample=bool(header.get("sample", False)),
            temperature=float(header.get("temperature", 0.7)),
            top_p=float(header.get("top_p", 0.95)),
        )
        ms = (time.monotonic() - started) * 1000

        # narrate the lifecycle: the prefill announces a question arriving at
        # THIS slice of the model; then a heartbeat line every 8 forwards so
        # the flow stays visible without a line per token. The counters are
        # shared across handler threads, so mutate them under the lock.
        with self._sessions_lock:
            n = self._sessions.get(session, 0) + 1
            self._sessions[session] = n
            if len(self._sessions) > 128:  # forgotten sessions must not accumulate
                self._sessions.pop(next(iter(self._sessions)))
        if tokens is not None and len(tokens) > 1:
            log.info("%s: prefill %d tokens through %s (%.0fms)",
                     session, len(tokens), self.stage.shard.label, ms)
        elif n % 8 == 0:
            log.info("%s: %d forwards through %s (~%.0fms/step)",
                     session, n, self.stage.shard.label, ms)

        if kind == "token":
            return wire.encode_frame({"kind": "token", "token": int(payload)})
        return wire.encode_frame({"kind": "hidden"}, payload)

    def reset(self, header: dict[str, Any]) -> bytes:
        session = str(header.get("session", "s0"))
        self._submit(self.stage.reset, session)
        with self._sessions_lock:
            n = self._sessions.pop(session, 0)
        if n:
            log.info("%s: done — %d forwards served by %s", session, n, self.stage.shard.label)
        return wire.encode_frame({"kind": "ok"})


def make_handler(host: ShardHost) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        # HTTP/1.1 so the driver's pooled client keeps ONE TCP connection per
        # shard instead of a fresh handshake per token — every response carries
        # a Content-Length, so keep-alive is safe. Default 1.0 closed each one.
        protocol_version = "HTTP/1.1"
        timeout = 30

        def log_message(self, *args):
            pass

        def _send(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _error(self, status: int, message: str) -> None:
            import json

            self._send(status, json.dumps({"error": message}).encode(), "application/json")

        def _authed(self) -> bool:
            got = self.headers.get("Authorization", "")
            if not got.startswith("Bearer "):
                return False
            return host.authorized(got[len("Bearer ") :])

        def _read_frame(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            if length > MAX_FRAME:
                raise ValueError("frame too large")
            raw = self.rfile.read(length) if length else b""
            return wire.decode_frame(raw)

        def do_GET(self):
            if self.path == "/healthz":
                import json

                body = json.dumps(
                    {"ok": True, "model": host.model_id, "shard": host.stage.shard.label}
                ).encode()
                self._send(200, body, "application/json")
            else:
                self._error(404, "not found")

        def do_POST(self):
            route = {"/pipeline/forward": host.forward, "/pipeline/reset": host.reset}.get(self.path)
            if route is None:
                return self._error(404, "not found")
            if not self._authed():
                return self._error(401, "unauthorized")
            try:
                header, tensor = self._read_frame()
            except ValueError as exc:
                return self._error(400, str(exc))
            try:
                out = route(header, tensor) if self.path == "/pipeline/forward" else route(header)
            except ShardOverloaded as exc:
                return self._error(503, str(exc))
            except ValueError as exc:
                return self._error(400, str(exc))
            except Exception:
                log.exception("shard step failed")
                return self._error(500, "shard step failed")
            self._send(200, out, "application/octet-stream")

    return Handler


def make_server(host: ShardHost, bind: str = "127.0.0.1", port: int = DEFAULT_SHARD_PORT):
    return ThreadingHTTPServer((bind, port), make_handler(host))


# ── exchange registration ────────────────────────────────────────────────────


class ShardCatalog:
    """Registers this shard with the exchange's pipeline catalog and heartbeats.

    Hands the exchange the shard's ``secret`` at registration so a driver that
    leases the pipeline (authenticated to the exchange) can reach us — the same
    reachable-but-never-open contract as ``serve-llm``. Mirrors that daemon's
    catalog contract (``register``/``heartbeat``/``deregister`` + ``ttl_seconds``)
    so it reuses the same heartbeat loop.
    """

    def __init__(self, server_url, model, index, count, url, secret, *, key, name=None, timeout=10.0):
        self.server_url = server_url.rstrip("/")
        self.model = model
        self.index = index
        self.count = count
        self.url = url
        self.secret = secret
        self.key = key
        self.name = name
        self.timeout = timeout
        self.host_id = None
        self.ttl_seconds = 60

    def _headers(self):
        return {"Authorization": f"Bearer {self.key}"} if self.key else {}

    def register(self) -> bool:
        import httpx

        payload = {
            "model": self.model,
            "index": self.index,
            "count": self.count,
            "url": self.url,
            "secret": self.secret,
            "name": self.name,
        }
        try:
            resp = httpx.post(
                f"{self.server_url}/api/pipelines/register",
                json=payload,
                headers=self._headers(),
                timeout=self.timeout,
            )
            resp.raise_for_status()
            data = (resp.json() or {}).get("data") or {}
        except (httpx.HTTPError, ValueError) as exc:
            log.warning("pipeline catalog register failed: %s", exc)
            return False
        self.host_id = data.get("id")
        ttl = data.get("ttl_seconds")
        if isinstance(ttl, (int, float)) and ttl > 0:
            self.ttl_seconds = int(ttl)
        if self.host_id is None:
            return False
        log.info("registered shard %s/%s of %s as %s", self.index, self.count, self.model, self.host_id)
        return True

    def heartbeat(self) -> bool:
        import httpx

        if self.host_id is None:
            return self.register()
        try:
            resp = httpx.post(
                f"{self.server_url}/api/pipelines/{self.host_id}/heartbeat",
                headers=self._headers(),
                timeout=self.timeout,
            )
            resp.raise_for_status()
        except (httpx.HTTPError, ValueError) as exc:
            log.warning("pipeline catalog heartbeat failed: %s; will re-register", exc)
            self.host_id = None
            return False
        return True

    def deregister(self) -> None:
        import httpx

        if self.host_id is None:
            return
        try:
            httpx.delete(
                f"{self.server_url}/api/pipelines/{self.host_id}",
                headers=self._headers(),
                timeout=self.timeout,
            )
            log.info("deregistered shard %s from the pipeline catalog", self.host_id)
        except httpx.HTTPError as exc:  # pragma: no cover - best-effort teardown
            log.warning("pipeline catalog deregister failed: %s", exc)
        self.host_id = None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="party-line-harness serve-shard",
        description="lend one pipeline shard of a model until you stop it",
    )
    parser.add_argument("--model", required=True, help="mlx-community model id (same on every shard)")
    parser.add_argument("--stage", required=True, help="which shard: 'i/n' (stage i of n) or 'a:b'")
    parser.add_argument("--port", type=int, default=DEFAULT_SHARD_PORT)
    parser.add_argument("--bind", default="127.0.0.1", help="local bind address (tailscale proxies to it)")
    parser.add_argument("--token", default=None, help="bearer secret (auto-generated if omitted)")
    parser.add_argument("--server", default=None, help="party-line exchange to register the shard with")
    parser.add_argument("--exchange-key", default=None, help="pl-… key authorizing you to lend a shard (from /keys)")
    parser.add_argument("--name", default=None, help="how the shard shows up in the catalog")
    parser.add_argument("--no-tailscale", action="store_true", help="serve localhost only")
    parser.add_argument("--funnel", action="store_true", help="expose to the public internet, not just the tailnet")
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    import signal

    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(message)s",
        datefmt="%H:%M:%S",
    )

    token = args.token or secrets.token_urlsafe(24)
    log.info("loading %s shard %s (first run downloads the weights)…", args.model, args.stage)
    # load THROUGH the host so all MLX work lives on its one worker thread
    host = ShardHost.load(args.model, args.stage, token=token)
    stage = host.stage
    log.info("shard ready: %s", stage.shard.label)
    httpd = make_server(host, bind=args.bind, port=args.port)
    bound_port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log.info("serving %s on %s:%d", stage.shard.label, args.bind, bound_port)

    public_url, used_tailscale = resolve_public_url(
        bound_port, funnel=args.funnel, no_tailscale=args.no_tailscale
    )
    banner = "=" * 60
    log.info(
        "\n%s\n  SHARD %s\n  url:    %s\n  secret: %s\n\n"
        "  drive it with:\n"
        "    party-line-harness pipeline-run --model %s \\\n"
        "      --stage %s=%s,<next-shard-url>=<its-secret> --prompt \"…\"\n%s",
        banner, stage.shard.label, public_url, token, args.model, public_url, token, banner,
    )

    # register with the exchange's pipeline catalog so it can be assembled +
    # leased; without a key we serve locally but don't register (identity-bound).
    catalog = None
    hb_stop = threading.Event()
    if args.server and args.exchange_key:
        if stage.shard.count < 2:
            # an "a:b" layer-range shard is a lone 0/1 stage — the catalog only
            # assembles i/n splits, so registering it would just 422
            log.warning(
                "--stage a:b shards can't be cataloged (the exchange assembles i/n splits); "
                "serving without registering"
            )
        else:
            catalog = ShardCatalog(
                args.server, args.model, stage.shard.index, stage.shard.count,
                public_url, token, key=args.exchange_key, name=args.name,
            )
            catalog.register()
            threading.Thread(target=_heartbeat_loop, args=(catalog, hb_stop), daemon=True).start()
    elif args.server:
        log.warning("no --exchange-key: serving locally but NOT registering (registration is identity-bound)")

    stopping = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stopping.set())
    signal.signal(signal.SIGTERM, lambda *_: stopping.set())
    log.info("shard on the line. Ctrl-C to stop.")
    stopping.wait()

    log.info("shutting down…")
    hb_stop.set()
    if catalog:
        catalog.deregister()
    if used_tailscale:
        stop_tailscale(funnel=args.funnel)
    httpd.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
