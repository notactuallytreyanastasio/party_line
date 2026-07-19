"""Pipeline package: the parts that don't need a model.

Layer partitioning, the binary wire frame, and the driver's stage-walking
orchestration are all exercised here with fakes. The MLX partial forward
(``stage.py``) is proven by ``pipeline/smoke.py`` on Apple hardware, per the
harness convention that the model path is smoke-verified, not unit-tested.
"""

from __future__ import annotations

import threading

import numpy as np
import pytest

from party_line_harness.pipeline import driver, wire
from party_line_harness.pipeline.shard import Shard, parse_stage_spec, partition_layers


# ── partitioning ────────────────────────────────────────────────────────────


def test_partition_covers_every_layer_contiguously():
    shards = partition_layers(32, 3)
    assert [(s.start, s.end) for s in shards] == [(0, 10), (11, 21), (22, 31)]
    # every layer is owned exactly once, in order
    covered = [i for s in shards for i in range(s.start, s.end + 1)]
    assert covered == list(range(32))


def test_partition_hands_remainder_to_earliest_stages():
    shards = partition_layers(10, 3)
    assert [s.n_local for s in shards] == [4, 3, 3]


def test_only_first_shard_embeds_only_last_heads():
    a, b, c = partition_layers(12, 3)
    assert (a.has_embed, a.has_head) == (True, False)
    assert (b.has_embed, b.has_head) == (False, False)
    assert (c.has_embed, c.has_head) == (False, True)


def test_single_stage_owns_both_ends():
    (only,) = partition_layers(8, 1)
    assert only.has_embed and only.has_head


def test_partition_rejects_more_stages_than_layers():
    with pytest.raises(ValueError):
        partition_layers(2, 3)


def test_parse_stage_spec_forms():
    s = parse_stage_spec("1/2", 12)
    assert (s.start, s.end, s.index, s.count) == (6, 11, 1, 2)
    assert s.has_head and not s.has_embed

    r = parse_stage_spec("3:7", 12)
    assert (r.start, r.end) == (3, 7)


def test_shard_rejects_impossible_range():
    with pytest.raises(ValueError):
        Shard(start=5, end=2, n_layers=12, index=0, count=1)


# ── the wire frame ──────────────────────────────────────────────────────────


def test_frame_header_only_round_trips():
    raw = wire.encode_frame({"kind": "token", "token": 42})
    header, tensor = wire.decode_frame(raw)
    assert header == {"kind": "token", "token": 42}
    assert tensor is None


def test_frame_tensor_round_trips_shape_and_values():
    h = np.arange(2 * 3 * 4, dtype=np.float32).reshape(1, 6, 4)
    raw = wire.encode_frame({"kind": "hidden"}, h)
    header, tensor = wire.decode_frame(raw)
    assert header == {"kind": "hidden"}
    assert tensor.shape == (1, 6, 4)
    assert np.array_equal(tensor, h)


def test_frame_casts_to_float32_losslessly_for_fp16():
    # a hidden state a model emits in fp16: float32 holds every value exactly
    h16 = (np.random.default_rng(0).standard_normal((1, 5, 8)).astype(np.float16))
    raw = wire.encode_frame({"kind": "hidden"}, h16)
    _, tensor = wire.decode_frame(raw)
    assert tensor.dtype == np.float32
    assert np.array_equal(tensor, h16.astype(np.float32))


def test_decode_rejects_garbage():
    with pytest.raises(ValueError):
        wire.decode_frame(b"not a frame at all")


def test_decode_rejects_truncated_header():
    raw = wire.encode_frame({"kind": "hidden"}, np.zeros((1, 2, 2), np.float32))
    with pytest.raises(ValueError):
        wire.decode_frame(raw[:6])


# ── the driver orchestration (fake transport, no model) ─────────────────────


class FakeTransport:
    """A toy 2-stage pipeline over a 1-D 'hidden state'.

    Stage 0 embeds a token into a vector; interior stages add their bias; the
    last stage 'samples' by mapping the vector to a next token deterministically.
    Records the call order so the driver's sequencing can be asserted.
    """

    def __init__(self, n_stages: int, vocab: int = 100):
        self.n_stages = n_stages
        self.vocab = vocab
        self.resets: list[str] = []
        self.calls: list[tuple[int, str, str]] = []

    def reset(self, session: str) -> None:
        self.resets.append(session)

    def call(self, stage, session, *, tokens, hidden, want, sample, temperature, top_p):
        self.calls.append((stage, want, "tok" if tokens is not None else "hid"))
        if stage == 0:
            assert tokens is not None and hidden is None
            h = np.array([float(tokens[-1])], dtype=np.float32)
        else:
            assert hidden is not None and tokens is None
            h = np.asarray(hidden, dtype=np.float32) + stage
        if want == "token":
            return "token", int((h[0] + 1) % self.vocab)
        return "hidden", h


def test_driver_walks_stages_in_order_and_feeds_hidden_forward():
    t = FakeTransport(n_stages=3)
    out = driver.generate(t, [7], max_tokens=1)
    # 7 -> stage0 hidden [7]; +1 -> [8]; +2 -> [10]; last: (10+1)%100 = 11
    assert out == [11]
    # exactly one pass over all three stages, in order, last wanting a token
    assert t.calls == [(0, "hidden", "tok"), (1, "hidden", "hid"), (2, "token", "hid")]
    # reset at the start (fresh caches) AND the end (free the session's KV)
    assert t.resets == ["s0", "s0"]


def test_driver_feeds_each_token_back_into_stage_zero():
    t = FakeTransport(n_stages=2)
    out = driver.generate(t, [3], max_tokens=3)
    # step: tok -> [t]; +1 -> [t+1]; token = (t+2)%100. 3->5, 5->7, 7->9
    assert out == [5, 7, 9]
    # the decode steps feed a single fed-back token, not the prompt again
    stage0_inputs = [c for c in t.calls if c[0] == 0]
    assert all(kind == "tok" for _, _, kind in stage0_inputs)


def test_driver_stops_on_eos_without_emitting_it():
    t = FakeTransport(n_stages=2)
    # 3->5, 5->7, then 7 would produce 9 — make 9 the eos
    out = driver.generate(t, [3], max_tokens=10, eos_ids={9})
    assert out == [5, 7]


def test_single_stage_pipeline_still_runs():
    t = FakeTransport(n_stages=1)
    # stage 0 is also last: [4] -> token (4+1)%100 = 5
    out = driver.generate(t, [4], max_tokens=1)
    assert out == [5]
    assert t.calls == [(0, "token", "tok")]


# ── exchange lease + shard registration (fake exchange, no model) ────────────


class _FakeExchange:
    """Records register/lease calls; returns canned catalog responses."""

    def __init__(self, lease_stages=None, expires_at=4102444800, lease_stages_seq=None):
        self.lease_stages = lease_stages or [
            {"index": 1, "url": "http://b", "token": "tB"},
            {"index": 0, "url": "http://a", "token": "tA"},
        ]
        # optional: a different stage list per successive lease call — used to
        # simulate a shard restarting (new registration) between leases
        self.lease_stages_seq = lease_stages_seq
        self.expires_at = expires_at
        self.registered: list = []
        self.auth: list = []
        self.lease_calls = 0

    def current_stages(self):
        if self.lease_stages_seq:
            return self.lease_stages_seq[min(self.lease_calls - 1, len(self.lease_stages_seq) - 1)]
        return self.lease_stages

    def handler(self):
        import json
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
                if self.path == "/api/pipelines/register":
                    outer.registered.append(payload)
                    self._reply({"ok": True, "data": {"id": "sh0", "ttl_seconds": 45}})
                elif self.path == "/api/pipelines/lease":
                    outer.lease_calls += 1
                    self._reply(
                        {"ok": True, "data": {
                            "model": payload["model"],
                            "expires_at": outer.expires_at,
                            "stages": outer.current_stages(),
                        }}
                    )
                else:
                    self._reply({"ok": False})

        return H


def _serve_exchange(ex):
    import threading
    from http.server import ThreadingHTTPServer

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), ex.handler())
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, f"http://127.0.0.1:{httpd.server_address[1]}"


def test_lease_pipeline_returns_endpoints_ordered_by_stage():
    from party_line_harness.pipeline import driver

    ex = _FakeExchange()
    httpd, url = _serve_exchange(ex)
    try:
        lease = driver.lease_pipeline(url, "big-model", key="pl-abc")
        # exchange returned stages out of order; the driver sorts by index
        assert lease.endpoints == [("http://a", "tA"), ("http://b", "tB")]
        assert lease.expires_at == 4102444800
        assert ex.auth[-1] == "Bearer pl-abc"
    finally:
        httpd.shutdown()


# the same literal is asserted against PartyLine.Pipelines.lease_token/5 in the
# Elixir suite — a shared golden vector keeps both implementations honest
GOLDEN_SECRET = "topsecret"
GOLDEN_TOKEN = "plsl1.4102444800.DzpLeYVJbwyWkV1v-849eDtEuryatPHpbJK6leuvxbo"


def test_shard_verifies_the_exchanges_hmac_lease_token():
    from party_line_harness.pipeline.serve_shard import ShardHost

    # FakeStage is stage 0 of 2; the golden token is scoped to model "m", 0/2
    host = ShardHost(FakeStage(), "m", token=GOLDEN_SECRET)
    assert host.authorized(GOLDEN_TOKEN)  # the cross-language vector verifies
    assert host.authorized(GOLDEN_SECRET)  # the raw secret still works (manual wiring)

    # scoped: a shard serving a different model rejects the same token
    assert not ShardHost(FakeStage(), "other-model", token=GOLDEN_SECRET).authorized(GOLDEN_TOKEN)
    # expired, malformed, and wrong-key tokens all fail
    assert not host.authorized("plsl1.123." + GOLDEN_TOKEN.rsplit(".", 1)[1])
    assert not host.authorized("nonsense")
    assert not ShardHost(FakeStage(), "m", token="wrong").authorized(GOLDEN_TOKEN)


def test_shard_catalog_registers_stage_model_and_key():
    from party_line_harness.pipeline.serve_shard import ShardCatalog

    ex = _FakeExchange()
    httpd, url = _serve_exchange(ex)
    try:
        cat = ShardCatalog(url, "big-model", 1, 2, "http://me.ts.net", "sekret", key="pl-xyz", name="closet")
        assert cat.register() is True
        assert cat.host_id == "sh0" and cat.ttl_seconds == 45
        sent = ex.registered[-1]
        assert sent["model"] == "big-model" and sent["index"] == 1 and sent["count"] == 2
        assert sent["url"] == "http://me.ts.net" and sent["secret"] == "sekret"
        assert ex.auth[-1] == "Bearer pl-xyz"
    finally:
        httpd.shutdown()


# ── pipeline-host: an assembled pipeline as a lent model (no model) ─────────


class _FakeDetok:
    """Mirrors mlx's streaming contract: ``text`` grows as tokens land, and
    ``last_segment`` returns (and consumes) the growth since the last read."""

    def __init__(self):
        self.reset()

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
        piece = self.text[self._read :]
        self._read = len(self.text)
        return piece


class FakeTokenizer:
    """Just enough tokenizer for the driver: template → ids, ids → text."""

    eos_token_id = 99

    def __init__(self):
        self.detokenizer = _FakeDetok()

    def apply_chat_template(self, messages, add_generation_prompt=True, **_kw):
        return list(range(1, len(messages) + 2))


def test_pipeline_host_completes_a_chat_over_a_leased_pipeline():
    """The capstone loop, model-free: OpenAI body → PipelineChat → lease from a
    fake exchange → HttpTransport → two secret-gated shards → completion text."""
    from party_line_harness.pipeline.host import PipelineChat
    from party_line_harness.pipeline.serve_shard import ShardHost

    # two shards whose secrets equal the lease tokens the fake exchange mints
    d0, p0 = _serve(ShardHost(FakeStage(), "m", token="tA"))
    d1, p1 = _serve(ShardHost(FakeStage(), "m", token="tB"))
    ex = _FakeExchange(
        lease_stages=[
            {"index": 1, "url": f"http://127.0.0.1:{p1}", "token": "tB"},
            {"index": 0, "url": f"http://127.0.0.1:{p0}", "token": "tA"},
        ]
    )
    dex, ex_url = _serve_exchange(ex)
    chat = PipelineChat(ex_url, "m", "pl-key", tokenizer=FakeTokenizer())
    try:
        text = chat.chat({"messages": [{"role": "user", "content": "hi"}], "max_tokens": 3})
        assert text == "t123 t123 t123"  # FakeStage's last stage always samples 123

        # a far-future lease is reused, not re-taken per request
        chat.chat({"messages": [{"role": "user", "content": "again"}], "max_tokens": 1})
        assert ex.lease_calls == 1
    finally:
        chat.close()
        dex.shutdown()
        d0.shutdown()
        d1.shutdown()


def test_pipeline_chat_re_leases_when_the_lease_nears_expiry():
    import time as _time

    from party_line_harness.pipeline.host import PipelineChat
    from party_line_harness.pipeline.serve_shard import ShardHost

    d0, p0 = _serve(ShardHost(FakeStage(), "m", token="tA"))
    # expires inside the margin → every chat takes a fresh lease
    ex = _FakeExchange(
        lease_stages=[{"index": 0, "url": f"http://127.0.0.1:{p0}", "token": "tA"}],
        expires_at=int(_time.time()) + 5,
    )
    dex, ex_url = _serve_exchange(ex)
    chat = PipelineChat(ex_url, "m", "pl-key", tokenizer=FakeTokenizer(), lease_margin=60.0)
    try:
        chat.chat({"messages": [{"role": "user", "content": "one"}], "max_tokens": 1})
        chat.chat({"messages": [{"role": "user", "content": "two"}], "max_tokens": 1})
        assert ex.lease_calls == 2
    finally:
        chat.close()
        dex.shutdown()
        d0.shutdown()


def test_http_transport_names_the_dead_hop():
    """A failed stage raises StageError carrying WHICH hop died."""
    from party_line_harness.pipeline.serve_shard import ShardHost

    d0, p0 = _serve(ShardHost(FakeStage(), "m", token="s0"))
    d1, p1 = _serve(ShardHost(FakeStage(), "m", token="s1"))
    # stage 1 dies: shutdown stops the loop, server_close frees the socket —
    # without the close, the OS backlog would ACCEPT (and hang) connections
    d1.shutdown()
    d1.server_close()

    transport = driver.HttpTransport(
        [(f"http://127.0.0.1:{p0}", "s0"), (f"http://127.0.0.1:{p1}", "s1")],
        timeout=5.0,
    )
    try:
        # healthz preflight names it without spending a generation
        assert transport.healthz() == [(0, True), (1, False)]

        with pytest.raises(driver.StageError) as err:
            driver.generate(transport, [1], max_tokens=1, session="dead-hop")
        assert err.value.stage == 1
        assert f"127.0.0.1:{p1}" in str(err.value)
    finally:
        transport.close()
        d0.shutdown()


def test_pipeline_chat_heals_a_restarted_shard_by_re_leasing():
    """A dead hop mid-request triggers one re-lease-and-retry; because leases
    prefer the newest registration, a restarted shard recovers invisibly."""
    from party_line_harness.pipeline.host import PipelineChat
    from party_line_harness.pipeline.serve_shard import ShardHost

    # the shard that "restarted": the first lease points at its dead old port,
    # the second lease at its live new one
    d_dead, p_dead = _serve(ShardHost(FakeStage(), "m", token="tOld"))
    d_dead.shutdown()
    d_dead.server_close()  # actually free the socket so the port refuses
    d_live, p_live = _serve(ShardHost(FakeStage(), "m", token="tNew"))

    ex = _FakeExchange(
        lease_stages_seq=[
            [{"index": 0, "url": f"http://127.0.0.1:{p_dead}", "token": "tOld"}],
            [{"index": 0, "url": f"http://127.0.0.1:{p_live}", "token": "tNew"}],
        ]
    )
    dex, ex_url = _serve_exchange(ex)
    chat = PipelineChat(ex_url, "m", "pl-key", tokenizer=FakeTokenizer())
    try:
        text = chat.chat({"messages": [{"role": "user", "content": "hi"}], "max_tokens": 2})
        assert text == "t123 t123"  # healed: answered by the restarted shard
        assert ex.lease_calls == 2  # the failure cost exactly one re-lease
    finally:
        chat.close()
        dex.shutdown()
        d_live.shutdown()


def test_pipeline_host_http_surface_auth_completion_and_503():
    import httpx

    from party_line_harness.pipeline import host as host_mod

    class _StubChat:
        model = "big-model"

        def __init__(self, text=None):
            self.text = text

        def chat(self, payload):
            if self.text is None:
                raise host_mod.PipelineUnavailable("no complete pipeline for big-model")
            return self.text

    # happy path: an OpenAI chat.completion comes back, secret-gated
    httpd = host_mod.make_server(_StubChat("hello there"), "pipe", "sek")
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        body = {"messages": [{"role": "user", "content": "hi"}]}
        r = httpx.post(f"http://127.0.0.1:{port}/v1/chat/completions", json=body)
        assert r.status_code == 401  # no secret → never open

        r = httpx.post(
            f"http://127.0.0.1:{port}/v1/chat/completions",
            json=body,
            headers={"Authorization": "Bearer sek"},
        )
        assert r.status_code == 200
        out = r.json()
        assert out["object"] == "chat.completion"
        assert out["model"] == "big-model"
        assert out["choices"][0]["message"]["content"] == "hello there"

        h = httpx.get(f"http://127.0.0.1:{port}/healthz")
        assert h.status_code == 200 and h.json()["assembled"] is True
    finally:
        httpd.shutdown()

    # no pipeline live → 503, so the exchange's caller gets a clean error
    httpd = host_mod.make_server(_StubChat(None), "pipe", "sek")
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        r = httpx.post(
            f"http://127.0.0.1:{port}/v1/chat/completions",
            json={"messages": [{"role": "user", "content": "hi"}]},
            headers={"Authorization": "Bearer sek"},
        )
        assert r.status_code == 503
    finally:
        httpd.shutdown()

    # a hop still dead after the retry → 502, naming the hop
    class _DeadHopChat:
        model = "big-model"

        def chat(self, payload):
            raise driver.StageError(1, "http://b:8378", RuntimeError("connect refused"))

    httpd = host_mod.make_server(_DeadHopChat(), "pipe", "sek")
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        r = httpx.post(
            f"http://127.0.0.1:{port}/v1/chat/completions",
            json={"messages": [{"role": "user", "content": "hi"}]},
            headers={"Authorization": "Bearer sek"},
        )
        assert r.status_code == 502
        assert "stage 1" in r.json()["error"]
    finally:
        httpd.shutdown()


# ── serve-shard HTTP surface (fake stage, no model) ─────────────────────────


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


def _serve(host):
    import threading
    from http.server import ThreadingHTTPServer

    from party_line_harness.pipeline.serve_shard import make_handler

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(host))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


def test_serve_shard_requires_the_secret():
    import httpx

    from party_line_harness.pipeline.serve_shard import ShardHost

    host = ShardHost(FakeStage(), "some-model", token="sekret")
    httpd, port = _serve(host)
    try:
        frame = wire.encode_frame({"session": "s0", "want": "hidden", "tokens": [1]})
        # no auth header -> 401
        r = httpx.post(f"http://127.0.0.1:{port}/pipeline/forward", content=frame)
        assert r.status_code == 401
        # with the secret -> 200 and a hidden frame back
        r = httpx.post(
            f"http://127.0.0.1:{port}/pipeline/forward",
            content=frame,
            headers={"Authorization": "Bearer sekret"},
        )
        assert r.status_code == 200
        header, tensor = wire.decode_frame(r.content)
        assert header["kind"] == "hidden"
        assert tensor is not None
    finally:
        httpd.shutdown()


# ── splittability guard (fake models, no MLX) ───────────────────────────────


class _GoodLayer:
    def __call__(self, x, mask=None, cache=None):
        return x


class _MatformerLayer:
    def __call__(self, x, mask=None, cache=None, per_layer_input=None, shared_kv=None):
        return x


def _fake_model(layers, n_caches, *, nested=False):
    class _W:
        dtype = "f32"

    trunk = type("Trunk", (), {})()
    trunk.layers = list(layers)
    trunk.norm = type("N", (), {"weight": _W()})()
    trunk.embed_tokens = type("E", (), {"weight": _W(), "as_linear": staticmethod(lambda x: x)})()
    attrs = {"model_type": "faketron", "make_cache": lambda self: [object() for _ in range(n_caches)]}
    attrs["language_model" if nested else "model"] = (
        type("LM", (), {"model": trunk})() if nested else trunk
    )
    return type("Model", (), attrs)(), trunk


def test_trunk_finds_flat_and_nested_trunks():
    from party_line_harness.pipeline.stage import _trunk

    flat, trunk = _fake_model([_GoodLayer()], 1)
    assert _trunk(flat) is trunk
    nested, trunk2 = _fake_model([_GoodLayer()], 1, nested=True)
    assert _trunk(nested) is trunk2


def test_trunk_rejects_a_model_with_no_decoder_trunk():
    from party_line_harness.pipeline.stage import _trunk

    with pytest.raises(ValueError):
        _trunk(type("X", (), {})())


def test_guard_accepts_a_plain_decoder_stack():
    from party_line_harness.pipeline.stage import _assert_splittable

    model, trunk = _fake_model([_GoodLayer() for _ in range(8)], 8)
    _assert_splittable(model, trunk)  # one cache per layer, plain forward → ok


def test_guard_rejects_shared_kv_matformer():
    from party_line_harness.pipeline.stage import _assert_splittable

    # gemma-4-e4b shape: fewer caches than layers (shared KV across layers)
    model, trunk = _fake_model([_GoodLayer() for _ in range(42)], 24)
    with pytest.raises(ValueError, match="shares KV"):
        _assert_splittable(model, trunk)


def test_guard_rejects_per_layer_inputs():
    from party_line_harness.pipeline.stage import _assert_splittable

    model, trunk = _fake_model([_MatformerLayer() for _ in range(8)], 8)
    with pytest.raises(ValueError, match="extra inputs"):
        _assert_splittable(model, trunk)


def test_shard_weight_files_selects_only_the_shards_files():
    from party_line_harness.pipeline.stage import shard_weight_files

    # 4 layers over 3 files; embed up front, head+norm at the back
    index = {"weight_map": {
        "model.embed_tokens.weight": "f1.safetensors",
        "model.layers.0.self_attn.q_proj.weight": "f1.safetensors",
        "model.layers.1.self_attn.q_proj.weight": "f2.safetensors",
        "model.layers.2.self_attn.q_proj.weight": "f2.safetensors",
        "model.layers.3.self_attn.q_proj.weight": "f3.safetensors",
        "model.norm.weight": "f3.safetensors",
        "lm_head.weight": "f3.safetensors",
    }}
    first, last = partition_layers(4, 2)

    # first shard: embed + layers 0-1 → f1, f2 — never the head's file
    assert shard_weight_files(index, first) == ["f1.safetensors", "f2.safetensors"]
    # last shard: layers 2-3 + norm + lm_head → f2, f3 — never the embed file...
    assert shard_weight_files(index, last) == ["f2.safetensors", "f3.safetensors"]


def test_shard_weight_files_tied_model_gives_the_head_the_embedding():
    from party_line_harness.pipeline.stage import shard_weight_files

    # no lm_head tensor: the embedding doubles as the head, so the LAST shard
    # needs the embed file too
    index = {"weight_map": {
        "model.embed_tokens.weight": "f1.safetensors",
        "model.layers.0.mlp.up_proj.weight": "f1.safetensors",
        "model.layers.1.mlp.up_proj.weight": "f2.safetensors",
        "model.norm.weight": "f2.safetensors",
    }}
    first, last = partition_layers(2, 2)

    assert shard_weight_files(index, first) == ["f1.safetensors"]
    assert shard_weight_files(index, last) == ["f1.safetensors", "f2.safetensors"]


def test_shard_weight_files_unclassified_tensors_go_everywhere():
    from party_line_harness.pipeline.stage import shard_weight_files

    # rotary tables and other small unclassified tensors ride with every shard
    index = {"weight_map": {
        "model.rotary_emb.inv_freq": "extras.safetensors",
        "model.layers.0.x.weight": "f1.safetensors",
        "model.layers.1.x.weight": "f2.safetensors",
        "lm_head.weight": "f2.safetensors",
    }}
    first, last = partition_layers(2, 2)

    assert "extras.safetensors" in shard_weight_files(index, first)
    assert "extras.safetensors" in shard_weight_files(index, last)


def test_stage_evicts_least_recently_used_session_beyond_cap():
    from party_line_harness.pipeline.stage import PipelineStage

    model, _ = _fake_model([_GoodLayer() for _ in range(4)], 4)
    st = PipelineStage(model, Shard(start=0, end=3, n_layers=4, index=0, count=1), max_sessions=2)

    a = st._cache_for("a")
    st._cache_for("b")
    assert st._cache_for("a") is a  # touching refreshes recency, same cache back
    st._cache_for("c")  # cap is 2 → evicts "b", the least recently used

    assert "b" not in st._caches
    assert "a" in st._caches and "c" in st._caches


def test_driver_generates_over_http_transport_end_to_end():
    """The full loop, model-free: driver.generate → HttpTransport → real
    sockets → two secret-gated ShardHosts. The same wiring pipeline-run uses."""
    from party_line_harness.pipeline.serve_shard import ShardHost

    stage0, stage1 = FakeStage(), FakeStage()
    h0 = ShardHost(stage0, "m", token="sek0")
    h1 = ShardHost(stage1, "m", token="sek1")
    d0, p0 = _serve(h0)
    d1, p1 = _serve(h1)
    transport = None
    try:
        transport = driver.HttpTransport(
            [(f"http://127.0.0.1:{p0}", "sek0"), (f"http://127.0.0.1:{p1}", "sek1")]
        )
        out = driver.generate(transport, [5, 6], max_tokens=3, session="e2e")
        assert out == [123, 123, 123]  # FakeStage's last stage always samples 123
        # both shards saw the session reset at start AND cleanup at end
        assert stage0.reset_calls == ["e2e", "e2e"]
        assert stage1.reset_calls == ["e2e", "e2e"]
    finally:
        if transport is not None:
            transport.close()
        d0.shutdown()
        d1.shutdown()


def test_serve_shard_forward_and_reset_and_health():
    import httpx

    from party_line_harness.pipeline.serve_shard import ShardHost

    stage = FakeStage()
    host = ShardHost(stage, "some-model", token="sekret")
    httpd, port = _serve(host)
    auth = {"Authorization": "Bearer sekret"}
    try:
        # health is open (no secret)
        h = httpx.get(f"http://127.0.0.1:{port}/healthz")
        assert h.status_code == 200 and h.json()["model"] == "some-model"

        # a token request comes back as a token frame
        frame = wire.encode_frame({"session": "s0", "want": "token"}, np.zeros((1, 1, 1), np.float32))
        r = httpx.post(f"http://127.0.0.1:{port}/pipeline/forward", content=frame, headers=auth)
        resp, tensor = wire.decode_frame(r.content)
        assert resp == {"kind": "token", "token": 123} and tensor is None

        # reset reaches the stage
        rr = httpx.post(
            f"http://127.0.0.1:{port}/pipeline/reset",
            content=wire.encode_frame({"session": "s9"}),
            headers=auth,
        )
        assert rr.status_code == 200 and stage.reset_calls == ["s9"]
    finally:
        httpd.shutdown()
