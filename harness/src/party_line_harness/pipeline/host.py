"""pipeline-host: front an assembled pipeline as a lent model on /v1.

The capstone of split inference. This daemon:

  * leases a ready pipeline for ``--model`` from the exchange, and re-leases
    before the tokens expire;
  * serves the OpenAI-shaped ``POST /v1/chat/completions`` (plus ``GET
    /healthz``) behind one secret, driving each request's tokens through the
    leased shards — it holds only the tokenizer, never a weight;
  * registers that endpoint in the exchange's **host catalog**, so the
    assembled model appears on the public ``/v1`` like any lent model.

Which means: a model no single machine could hold is now addressable by any
OpenAI client with an atproto key —

    caller ── pl-… key ──▶ exchange ── host secret ──▶ pipeline-host ─▶ shard A ─▶ shard B

and the exchange still never runs an inference step; it proxies to this daemon,
which is just another neighbor lending a model. No new server routes exist for
this: the capstone is pure composition (pipeline lease × host catalog).

Generations are serialized, one at a time through the pipeline. Concurrent
sessions would be *correct* (each keeps its own KV on the shards), but
hop-overlap scheduling is the planned perf work — until then, one at a time is
honest. A request while no complete pipeline is live gets a 503.
"""

from __future__ import annotations

import argparse
import json
import logging
import secrets
import threading
import time
import uuid
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from ..serve_llm import (
    Catalog,
    _heartbeat_loop,
    _norm_messages,
    _openai_completion,
    resolve_public_url,
    stop_tailscale,
)
from . import driver

log = logging.getLogger("party_line")

DEFAULT_HOST_PORT = 8379
# refresh the lease when it has less than this long to live, so a generation
# never starts on tokens about to expire mid-flight
LEASE_MARGIN_S = 60.0


class PipelineUnavailable(RuntimeError):
    """No complete pipeline for the model is live on the exchange."""


class PipelineChat:
    """The chat engine over a leased pipeline: tokenizer + transport, no weights.

    ``chat`` takes an OpenAI-shaped body and returns the completion text.
    Holds the current lease and swaps it (closing the old transport) when it
    nears expiry — safe because generations are serialized behind the lock.
    """

    def __init__(
        self,
        server: str,
        model: str,
        key: str | None,
        *,
        tokenizer: Any | None = None,
        lease_margin: float = LEASE_MARGIN_S,
    ):
        self.server = server
        self.model = model
        self.key = key
        self.lease_margin = lease_margin
        self.tokenizer = tokenizer if tokenizer is not None else driver.load_tokenizer(model)
        self._eos = driver.eos_token_ids(self.tokenizer)
        self._lease: driver.Lease | None = None
        self._transport: driver.HttpTransport | None = None
        self._lock = threading.Lock()  # one generation at a time (see moduledoc)

    def prime(self) -> None:
        """Take the first lease eagerly, so boot fails loudly when no pipeline
        is assembled yet (the daemon still serves; requests 503 until one is).
        Preflights every hop and names any that are unreachable."""
        with self._lock:
            transport = self._ensure_lease()
            for stage, ok in transport.healthz():
                if not ok:
                    log.warning("stage %d is unreachable — first request will fail it over", stage)

    def chat(self, payload: Any, on_text: Callable[[str], None] | None = None) -> str:
        """One completion for a /v1/chat/completions body. Raises ``ValueError``
        on a malformed body, ``PipelineUnavailable`` when nothing is leasable,
        ``driver.StageError`` when a hop is down and a fresh lease didn't heal it.

        A stage failure mid-generation triggers ONE re-lease-and-retry: leases
        pick the newest registration per slot, so a shard that crashed and came
        back — or whose token expired mid-flight — heals here without the caller
        seeing anything but latency. A shard that's still dead fails the retry
        with its hop named. The one exception is a streaming request that has
        already sent text: those bytes can't be recalled, so a heal there would
        re-emit the prefix — instead we re-raise and let the stream end cleanly.

        With ``on_text``, each decodable piece of text is delivered as it is
        sampled (driving the tokenizer's streaming detokenizer), and the full
        text is still returned. The callback runs on this thread, inside the
        lock — keep it fast; a slow consumer stalls the pipeline.
        """
        if not isinstance(payload, dict):
            raise ValueError("body must be a JSON object")
        messages = payload.get("messages")
        if not isinstance(messages, list) or not messages:
            raise ValueError("messages must be a non-empty array")
        max_tokens = int(payload.get("max_tokens") or 512)
        temperature = float(payload.get("temperature", 0.7))

        # one id follows the question everywhere: it is the shard session, so
        # this same id shows up in every shard's log — grep it across machines
        rid = f"chat-{uuid.uuid4().hex[:12]}"
        norm = _norm_messages(messages)
        asked = next((m["content"] for m in reversed(norm) if m["role"] == "user"), "")

        # the lifecycle narration: both modes drive the streaming detokenizer,
        # so the log shows the answer landing typewriter-style either way. The
        # detokenizer is shared, so ALL of its use stays inside the lock below.
        detok = self.tokenizer.detokenizer
        pieces: list[str] = []
        unlogged: list[str] = []
        n_tok = 0
        emitted = False  # has any text reached the client yet? (streaming only)

        def flush_log() -> None:
            if unlogged:
                log.info("%s ▸ %s", rid, "".join(unlogged).strip() or "…")
                unlogged.clear()

        def stream_token(tid: int) -> None:
            nonlocal n_tok, emitted
            n_tok += 1
            detok.add_token(tid)
            piece = detok.last_segment
            if piece:
                pieces.append(piece)
                unlogged.append(piece)
                if on_text is not None:
                    on_text(piece)
                    emitted = True
                if len(unlogged) >= 8:
                    flush_log()

        started = time.time()
        with self._lock:
            prompt_ids = driver.encode_prompt(self.tokenizer, norm)
            log.info('q %s: "%s" (%d prompt tokens)', rid, asked[:70], len(prompt_ids))
            for attempt in (1, 2):
                transport = self._ensure_lease()
                # retries restart from token zero — restart the stream state too,
                # or a healed retry would detokenize on stale context
                detok.reset()
                pieces.clear()
                unlogged.clear()
                n_tok = 0
                started = time.time()
                try:
                    driver.generate(
                        transport,
                        prompt_ids,
                        max_tokens=max_tokens,
                        eos_ids=self._eos,
                        # the request id IS the session: KV on the shards must
                        # never collide, and the logs correlate across machines
                        session=rid,
                        sample=temperature > 0,
                        temperature=temperature,
                        on_token=stream_token,
                    )
                    break
                except driver.StageError as exc:
                    self._invalidate()
                    # can't heal transparently once bytes are on the client's
                    # wire — a retry would re-emit the prefix, so end cleanly
                    if attempt == 2 or emitted:
                        raise
                    log.warning("%s — re-leasing and retrying once", exc)
            n_stages = transport.n_stages

            detok.finalize()
            tail = detok.last_segment
            if tail:
                pieces.append(tail)
                unlogged.append(tail)
                if on_text is not None:
                    on_text(tail)
            flush_log()

        elapsed = max(time.time() - started, 1e-6)
        log.info(
            "a %s: %d tokens in %.1fs (%.1f tok/s) across %d stages",
            rid, n_tok, elapsed, n_tok / elapsed, n_stages,
        )
        return "".join(pieces)

    def _invalidate(self) -> None:
        """Drop the current lease so the next attempt takes a fresh one."""
        if self._transport is not None:
            self._transport.close()
        self._transport = None
        self._lease = None

    def _ensure_lease(self) -> driver.HttpTransport:
        if (
            self._lease is not None
            and self._transport is not None
            and time.time() < self._lease.expires_at - self.lease_margin
        ):
            return self._transport

        import httpx

        try:
            lease = driver.lease_pipeline(self.server, self.model, key=self.key)
        except httpx.HTTPError as exc:
            raise PipelineUnavailable(f"no complete pipeline for {self.model}: {exc}") from exc
        if not lease.endpoints:
            raise PipelineUnavailable(f"no complete pipeline for {self.model}")

        if self._transport is not None:
            self._transport.close()
        self._lease = lease
        self._transport = driver.HttpTransport(lease.endpoints)
        log.info(
            "leased a %d-stage pipeline for %s (expires in %ds)",
            len(lease.endpoints),
            self.model,
            int(lease.expires_at - time.time()),
        )
        return self._transport

    def close(self) -> None:
        if self._transport is not None:
            self._transport.close()


# ── HTTP surface (what the exchange's host proxy calls) ─────────────────────


def make_handler(chat: PipelineChat, host_name: str, token: str) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        # HTTP/1.1 keep-alive for JSON completions (they carry Content-Length);
        # the SSE branch, which has none, opts back into close-delimiting.
        protocol_version = "HTTP/1.1"
        timeout = 15

        def log_message(self, *args):
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
            return secrets.compare_digest(got, f"Bearer {token}")

        def do_GET(self):
            if self.path == "/healthz":
                self._send(
                    200,
                    {"ok": True, "model": chat.model, "host_name": host_name, "assembled": True},
                )
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/v1/chat/completions":
                return self._send(404, {"error": "not found"})
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            length = int(self.headers.get("Content-Length", 0) or 0)
            if length > 1_000_000:
                return self._send(400, {"error": "request body too large"})
            try:
                payload = json.loads(self.rfile.read(length) if length else b"")
            except json.JSONDecodeError:
                return self._send(400, {"error": "malformed json"})
            if isinstance(payload, dict) and payload.get("stream"):
                return self._stream(payload)
            try:
                text = chat.chat(payload)
            except ValueError as exc:
                return self._send(400, {"error": str(exc)})
            except PipelineUnavailable as exc:
                return self._send(503, {"error": str(exc)})
            except driver.StageError as exc:
                # a hop is down and re-leasing didn't heal it — name the hop
                return self._send(502, {"error": str(exc)})
            except Exception:
                log.exception("pipeline generation failed")
                return self._send(500, {"error": "pipeline generation failed"})
            self._send(200, _openai_completion(text, chat.model))

        def _stream(self, payload: dict) -> None:
            """The SSE branch: OpenAI ``chat.completion.chunk`` events as tokens
            land, then a ``stop`` chunk and ``[DONE]``. Headers go out lazily on
            the first piece, so errors raised before any text still return the
            normal JSON statuses; once chunks are on the wire the only honest
            failure mode is to stop writing and close.
            """
            chunk_id = "chatcmpl-" + secrets.token_urlsafe(12)
            created = int(time.time())
            started = False

            def start() -> None:
                nonlocal started
                # SSE has no Content-Length and we don't chunk-encode, so the
                # body is delimited by connection close — opt out of the
                # handler's HTTP/1.1 keep-alive for this one response.
                self.close_connection = True
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                started = True

            def write_chunk(delta: dict, finish_reason: str | None) -> None:
                event = {
                    "id": chunk_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": chat.model,
                    "choices": [
                        {"index": 0, "delta": delta, "finish_reason": finish_reason}
                    ],
                }
                self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
                self.wfile.flush()

            def emit(piece: str) -> None:
                if not started:
                    start()
                write_chunk({"content": piece}, None)

            try:
                chat.chat(payload, on_text=emit)
            except ValueError as exc:
                if not started:
                    return self._send(400, {"error": str(exc)})
                return log.warning("stream aborted mid-flight: %s", exc)
            except PipelineUnavailable as exc:
                if not started:
                    return self._send(503, {"error": str(exc)})
                return log.warning("stream aborted mid-flight: %s", exc)
            except driver.StageError as exc:
                # a hop is down and re-leasing didn't heal it — name the hop
                if not started:
                    return self._send(502, {"error": str(exc)})
                return log.warning("stream aborted mid-flight: %s", exc)
            except Exception:
                log.exception("pipeline generation failed")
                if not started:
                    return self._send(500, {"error": "pipeline generation failed"})
                return
            if not started:  # an empty generation still gets a well-formed stream
                start()
            write_chunk({}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()

    return Handler


def make_server(
    chat: PipelineChat, host_name: str, token: str, bind: str = "127.0.0.1", port: int = 0
) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((bind, port), make_handler(chat, host_name, token))


# ── CLI / daemon ────────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="party-line-harness pipeline-host",
        description="front an assembled pipeline as a lent model on the exchange's /v1",
    )
    parser.add_argument("--model", required=True, help="the assembled model to lease and front")
    parser.add_argument("--server", required=True, help="the party-line exchange")
    parser.add_argument("--exchange-key", required=True, help="pl-… key (leases the pipeline AND owns the host entry)")
    parser.add_argument("--name", default=None, help="how the host shows up in the catalog")
    parser.add_argument("--port", type=int, default=DEFAULT_HOST_PORT)
    parser.add_argument("--bind", default="127.0.0.1", help="local bind address (tailscale proxies to it)")
    parser.add_argument("--llm-token", default=None, help="bearer secret (auto-generated if omitted)")
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
    if not args.verbose:
        # two "HTTP Request" lines per token would bury the lifecycle
        # narration; the per-hop chatter comes back with -v
        logging.getLogger("httpx").setLevel(logging.WARNING)

    token = args.llm_token or secrets.token_urlsafe(24)
    log.info("loading the tokenizer for %s (no weights on this machine)…", args.model)
    chat = PipelineChat(args.server, args.model, args.exchange_key)
    try:
        chat.prime()
    except PipelineUnavailable as exc:
        log.warning("%s — serving anyway; requests 503 until the shards appear", exc)

    name = (args.name or f"pipeline {args.model}")[:64]
    httpd = make_server(chat, name, token, bind=args.bind, port=args.port)
    bound_port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log.info("serving /v1/chat/completions on %s:%d", args.bind, bound_port)

    public_url, used_tailscale = resolve_public_url(
        bound_port, funnel=args.funnel, no_tailscale=args.no_tailscale
    )

    # register in the HOST catalog: from the exchange's point of view this is
    # just another lent model — the proxy, auth, and attribution all compose.
    catalog = Catalog(
        args.server, name, public_url, args.model, secret=token, key=args.exchange_key
    )
    catalog.register()
    hb_stop = threading.Event()
    threading.Thread(target=_heartbeat_loop, args=(catalog, hb_stop), daemon=True).start()

    banner = "=" * 60
    log.info(
        "\n%s\n  PIPELINE HOST %r\n  fronting: %s (assembled from shards, leased)\n"
        "  url:      %s\n\n  any OpenAI client reaches it through the exchange:\n"
        '    POST %s/v1/chat/completions  {"model": "%s", ...}\n%s',
        banner, name, args.model, public_url, args.server, args.model, banner,
    )

    stopping = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stopping.set())
    signal.signal(signal.SIGTERM, lambda *_: stopping.set())
    log.info("on the line. Ctrl-C to stop and take the pipeline home.")
    stopping.wait()

    log.info("shutting down…")
    hb_stop.set()
    catalog.deregister()
    if used_tailscale:
        stop_tailscale(funnel=args.funnel)
    httpd.shutdown()
    chat.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
