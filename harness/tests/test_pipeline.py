"""Pipeline package: the parts that don't need a model.

Layer partitioning, the binary wire frame, and the driver's stage-walking
orchestration are all exercised here with fakes. The MLX partial forward
(``stage.py``) is proven by ``pipeline/smoke.py`` on Apple hardware, per the
harness convention that the model path is smoke-verified, not unit-tested.
"""

from __future__ import annotations

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
    assert t.resets == ["s0"]


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


# ── serve-shard HTTP surface (fake stage, no model) ─────────────────────────


class FakeStage:
    def __init__(self):
        self.shard = type("S", (), {"label": "stage 0/2 layers 0-5"})()
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
    trunk = type("Trunk", (), {"layers": list(layers)})()
    attrs = {"model_type": "faketron", "make_cache": lambda self: [object()] * n_caches}
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
