"""serve-shard: lend one slice of a model to a pipeline.

Loads a single shard (``--stage i/n``) and serves its partial forward over
HTTP, behind the same secret gate ``serve-llm`` uses — a driver presents the
secret, relays hidden states through the ordered shards, and the last shard
samples. Two of these on two machines (``--stage 0/2`` and ``--stage 1/2``,
same ``--model``) are a two-machine model.

The wire is the binary frame in ``wire.py``: ``POST /pipeline/forward`` takes a
header + optional hidden tensor and returns a hidden tensor or a token;
``POST /pipeline/reset`` drops a session's caches; ``GET /healthz`` is open.

MLX wants one generation at a time, so every step is serialized behind a lock —
concurrent driver calls queue exactly as persona clients do in ``serve-llm``.
The catalog/lease side (having the exchange assemble a pipeline from advertised
shards) is deliberately not here yet: this is the harness half — two shards and
a driver that speaks to them — proven first.
"""

from __future__ import annotations

import argparse
import logging
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from ..serve_llm import resolve_public_url, stop_tailscale
from . import wire
from .stage import PipelineStage

log = logging.getLogger("party_line")

DEFAULT_SHARD_PORT = 8378
# a prefill hidden state is [1, seq, hidden] float32 — tens of MB for a long
# prompt on a wide model; give the body a generous ceiling, not a prompt-sized one.
MAX_FRAME = 512_000_000


class ShardHost:
    """A loaded shard plus the lock that serializes Metal work across the
    threaded HTTP handlers."""

    def __init__(self, stage: PipelineStage, model_id: str, token: str):
        self.stage = stage
        self.model_id = model_id
        self.token = token
        self._lock = threading.Lock()

    def forward(self, header: dict[str, Any], tensor) -> bytes:
        session = str(header.get("session", "s0"))
        want = header.get("want", "hidden")
        tokens = header.get("tokens")
        with self._lock:
            kind, payload = self.stage.step(
                session,
                tokens=tokens,
                hidden=tensor,
                want=want,
                sample=bool(header.get("sample", False)),
                temperature=float(header.get("temperature", 0.7)),
                top_p=float(header.get("top_p", 0.95)),
            )
        if kind == "token":
            return wire.encode_frame({"kind": "token", "token": int(payload)})
        return wire.encode_frame({"kind": "hidden"}, payload)

    def reset(self, header: dict[str, Any]) -> bytes:
        with self._lock:
            self.stage.reset(str(header.get("session", "s0")))
        return wire.encode_frame({"kind": "ok"})


def make_handler(host: ShardHost) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
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
            return secrets.compare_digest(got, f"Bearer {host.token}")

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
            except ValueError as exc:
                return self._error(400, str(exc))
            except Exception:
                log.exception("shard step failed")
                return self._error(500, "shard step failed")
            self._send(200, out, "application/octet-stream")

    return Handler


def make_server(host: ShardHost, bind: str = "127.0.0.1", port: int = DEFAULT_SHARD_PORT):
    return ThreadingHTTPServer((bind, port), make_handler(host))


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
    stage = PipelineStage.load(args.model, args.stage)
    log.info("shard ready: %s", stage.shard.label)

    host = ShardHost(stage, args.model, token)
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

    stopping = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stopping.set())
    signal.signal(signal.SIGTERM, lambda *_: stopping.set())
    log.info("shard on the line. Ctrl-C to stop.")
    stopping.wait()

    log.info("shutting down…")
    if used_tailscale:
        stop_tailscale(funnel=args.funnel)
    httpd.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
