"""One pipeline stage: a contiguous block of an mlx-lm model's layers, run as a
partial forward over hidden states.

This is the only MLX-touching module in the package, and it mirrors the layer
loop inside ``LlamaModel.__call__`` exactly — same masks (full + optional
sliding-window), same per-layer KV cache — but iterates only the shard's slice:

  * the first shard embeds token ids into hidden states;
  * every shard runs its layers, updating its own caches;
  * the last shard applies the final norm + lm_head and samples a token.

Because each stage advances its caches by the same tokens in lockstep, every
cache's ``offset`` (and therefore RoPE position) stays identical across the
pipeline without a position ever crossing the wire — only the hidden state does.

Correctness is verified end-to-end by ``pipeline/smoke.py`` (a split run must
generate the exact same greedy tokens as the whole model in one process); it is
not unit-tested, per the harness convention that the MLX path is smoke-verified.
"""

from __future__ import annotations

from typing import Any

import inspect
import json
import re
from collections import OrderedDict
from pathlib import Path

import numpy as np

from .shard import Shard, parse_stage_spec

# A splittable layer's forward is h = layer(x, mask, cache). Extra parameters mean
# the layer needs information a pipeline shard can't provide in isolation — a
# matformer's per-layer embeddings, or a key/value tensor shared with a layer that
# may live on another shard. We refuse those rather than emit silent garbage.
_LAYER_OK = {"self", "x", "mask", "cache", "inputs", "hidden_states", "h"}


def _trunk(model: Any) -> Any:
    """The transformer trunk that holds ``embed_tokens`` / ``layers`` / ``norm``.

    mlx-lm wraps it as ``model.model`` for the Llama/Qwen/Mistral/Gemma-2 families,
    and as ``model.language_model.model`` for the multimodal wrappers (gemma-3/4).
    """
    for path in ("model", "language_model.model"):
        inner = model
        for attr in path.split("."):
            inner = getattr(inner, attr, None)
        if inner is not None and hasattr(inner, "layers"):
            return inner
    raise ValueError("unsupported model: could not find a decoder trunk with .layers")


def _assert_splittable(model: Any, trunk: Any) -> None:
    """Refuse architectures a contiguous layer split can't run correctly.

    Two signals catch the matformer / shared-KV designs (e.g. gemma-4-e4b):
    every layer must own a KV cache (no cross-layer sharing), and its forward
    must be the plain ``layer(x, mask, cache)`` — no per-layer inputs. A model
    that fails either would produce garbage under a naive split, so we stop it at
    load time with a clear reason instead.
    """
    layers = trunk.layers
    try:
        n_caches = len(model.make_cache())
    except Exception:
        n_caches = len(layers)
    if n_caches != len(layers):
        raise ValueError(
            f"{_model_name(model)} shares KV across layers ({n_caches} caches for "
            f"{len(layers)} layers) — a pipeline split needs one cache per layer, so it "
            "can't be split cleanly across machines"
        )
    extra = set(inspect.signature(layers[0].__call__).parameters) - _LAYER_OK
    if extra:
        raise ValueError(
            f"{_model_name(model)} layers take extra inputs {sorted(extra)} (per-layer "
            "embeddings or shared KV) — a pipeline split supports plain decoder stacks only"
        )


def _model_name(model: Any) -> str:
    return getattr(model, "model_type", None) or model.__class__.__module__.rsplit(".", 1)[-1]


def shard_weight_files(index: dict, shard: Shard) -> list[str]:
    """Which safetensors files hold this shard's tensors — pure selection over
    a ``model.safetensors.index.json`` weight map, so a machine downloads only
    the files its slice needs.

    Layer tensors go to the shard whose range covers them; the embedding to the
    first shard (and to the last, when the model ties it as the head); the head
    and final norm to the last; small unclassified tensors (rotary tables and
    the like) to everyone. File granularity means a file mixing two shards'
    layers is fetched by both — the win shrinks as files grow, and a
    single-file model has nothing to skip.
    """
    weight_map = index["weight_map"]
    tied = not any("lm_head" in name for name in weight_map)
    needed: set[str] = set()
    for name, fname in weight_map.items():
        if m := re.search(r"\.layers\.(\d+)\.", name):
            if shard.start <= int(m.group(1)) <= shard.end:
                needed.add(fname)
        elif "embed_tokens" in name:
            if shard.has_embed or (shard.has_head and tied):
                needed.add(fname)
        elif "lm_head" in name or ".norm." in name or name.endswith(".norm.weight"):
            if shard.has_head:
                needed.add(fname)
        else:
            needed.add(fname)
    return sorted(needed)


def _config_layers(config: dict) -> int:
    n = config.get("num_hidden_layers") or (config.get("text_config") or {}).get(
        "num_hidden_layers"
    )
    if not n:
        raise ValueError("config.json has no num_hidden_layers — can't size the shard")
    return int(n)


class PipelineStage:
    """A loaded shard, ready to run its slice of the forward pass.

    Stateful across a generation: KV caches accumulate per ``session`` id, so
    ``reset(session)`` before a fresh prompt. Sessions are capped at
    ``max_sessions`` with least-recently-used eviction — KV caches are
    gigabyte-scale, so a caller minting fresh session ids (or a driver that
    died before cleanup) must not grow memory without bound.
    """

    def __init__(
        self, model: Any, shard: Shard, *, layer_offset: int | None = None, max_sessions: int = 8
    ):
        # where this shard's layers begin in ``model.model.layers``: ``shard.start``
        # when the model is the whole thing (shared across in-process stages), or
        # 0 when the model has been pruned to just this shard (``load``).
        offset = shard.start if layer_offset is None else layer_offset
        self.model = model
        self.shard = shard
        self._inner = _trunk(model)
        _assert_splittable(model, self._inner)
        self._cache_range = (offset, offset + shard.n_local)
        self._layers = list(self._inner.layers)[offset : offset + shard.n_local]
        # the *activation* dtype (fp16/bf16), read off the shard's OWN layers —
        # NOT embed_tokens.weight (packed uint32 on a quantized model) and NOT
        # the final norm (which only the head shard loads under partial fetch).
        self._dtype = self._activation_dtype()
        # a sliding-window model (e.g. gemma) needs a second, windowed mask for
        # its sliding layers; a plain causal model leaves this off.
        self._sliding_window = getattr(self._inner, "sliding_window", None)
        self._has_sliding = any(getattr(l, "use_sliding", False) for l in self._layers)
        self._head = self._resolve_head(model)
        self._max_sessions = max_sessions
        self._caches: OrderedDict[str, list] = OrderedDict()

    @classmethod
    def load(cls, model_id: str, stage_spec: str) -> "PipelineStage":
        """Load **only this shard's weights** — a fraction of the RAM and, for
        multi-file models, a fraction of the download and disk too.

        The tiny json files come first, so the shard can be sized before any
        weight moves; then only the safetensors files holding this shard's
        tensors are fetched (`shard_weight_files`); then the skeleton is built
        and whatever files are present are lazily memory-mapped —
        ``strict=False`` tolerates the absent far-shard files, whose layers are
        pruned away before anything could touch their unassigned weights. Only
        the tensors this shard runs are materialized: its layer block, plus the
        embedding on the first shard and the norm + lm_head on the last. A
        stage never loads a tokenizer.

        A single-file model (this 4-bit 8B ships as one ``model.safetensors``)
        still fetches its whole file — the RAM stays fractional either way; the
        disk win needs the multi-file packing that bigger models use.
        """
        import mlx.core as mx
        from mlx_lm.utils import load_model

        local = Path(model_id)
        if local.exists():
            path = local
        else:
            from huggingface_hub import snapshot_download

            # jsons only: enough to size the shard without touching a weight
            path = Path(snapshot_download(model_id, allow_patterns=["*.json"]))
            config = json.loads((path / "config.json").read_text())
            shard = parse_stage_spec(stage_spec, _config_layers(config))
            index_file = path / "model.safetensors.index.json"
            if index_file.exists():
                files = shard_weight_files(json.loads(index_file.read_text()), shard)
                snapshot_download(model_id, allow_patterns=["*.json", *files])
            else:
                snapshot_download(model_id, allow_patterns=["*.json", "*.safetensors"])

        config = json.loads((path / "config.json").read_text())
        shard = parse_stage_spec(stage_spec, _config_layers(config))

        model, _config = load_model(path, lazy=True, strict=False)
        inner = _trunk(model)
        _assert_splittable(model, inner)  # refuse matformer / shared-KV models up front

        # drop references to the layers this shard doesn't run; the pruned model's
        # layers are now 0-indexed, so the stage runs at layer_offset 0.
        inner.layers = inner.layers[shard.start : shard.end + 1]

        # materialize only what this shard touches — never the far endpoint.
        keep: list[Any] = [layer.parameters() for layer in inner.layers]
        if shard.has_embed:
            keep.append(inner.embed_tokens.parameters())
        if shard.has_head:
            keep.append(inner.norm.parameters())
            head = getattr(model, "lm_head", None)
            keep.append((head if head is not None else inner.embed_tokens).parameters())
        mx.eval(keep)

        return cls(model, shard, layer_offset=0)

    def _resolve_head(self, model: Any) -> Any:
        """The projection from hidden state to vocab logits: a dedicated
        ``lm_head`` when untied, else the embedding used as a linear (tied)."""
        head = getattr(model, "lm_head", None)
        if head is not None:
            return head
        return self._inner.embed_tokens.as_linear

    def _activation_dtype(self):
        """First floating-point weight in this shard's own layers (a quantized
        layer's scales/norms are stored in the activation dtype). Falls back to
        the trunk norm for stub models in tests."""
        try:
            import mlx.core as mx
            from mlx.utils import tree_flatten

            for _name, arr in tree_flatten(self._layers[0].parameters()):
                if mx.issubdtype(arr.dtype, mx.floating):
                    return arr.dtype
        except Exception:  # noqa: BLE001 - stubs have no parameters()
            pass
        return self._inner.norm.weight.dtype

    def reset(self, session: str) -> None:
        self._caches.pop(session, None)

    def _cache_for(self, session: str) -> list:
        cache = self._caches.get(session)
        if cache is None:
            # evict the least-recently-used session before admitting a new one
            if len(self._caches) >= self._max_sessions:
                self._caches.popitem(last=False)
            # the model builds the right cache type per layer (rotating for
            # sliding layers, plain KV otherwise); take just this shard's slice.
            lo, hi = self._cache_range
            cache = self.model.make_cache()[lo:hi]
            self._caches[session] = cache
        else:
            self._caches.move_to_end(session)
        return cache

    def step(
        self,
        session: str,
        *,
        tokens: list[int] | None = None,
        hidden: np.ndarray | None = None,
        want: str = "hidden",
        sample: bool = False,
        temperature: float = 0.7,
        top_p: float = 0.95,
    ) -> tuple[str, Any]:
        """Advance this shard by one step.

        The first shard is called with ``tokens`` (the prompt on prefill, a
        single token on decode); later shards with ``hidden``. Returns
        ``("hidden", ndarray)`` for an interior shard, or ``("token", int)``
        when ``want == "token"`` (the last shard).
        """
        import mlx.core as mx
        from mlx_lm.models.base import create_attention_mask

        cache = self._cache_for(session)

        if self.shard.has_embed and tokens is not None:
            h = self._inner.embed_tokens(mx.array([list(tokens)]))
        elif hidden is not None:
            h = mx.array(np.asarray(hidden, dtype=np.float32)).astype(self._dtype)
        else:
            raise ValueError("step needs tokens (first shard) or hidden (later shard)")

        # masks come off this shard's own cache offset — identical to every
        # other shard's, since all advance in lockstep.
        fa_mask = create_attention_mask(h, cache[0])
        swa_mask = (
            create_attention_mask(h, cache[0], window_size=self._sliding_window)
            if self._has_sliding
            else None
        )
        for layer, c in zip(self._layers, cache):
            mask = swa_mask if getattr(layer, "use_sliding", False) else fa_mask
            h = layer(h, mask, cache=c)

        if not self.shard.has_head or want != "token":
            mx.eval(h)
            return "hidden", np.array(h.astype(mx.float32))

        # last shard: final norm + lm_head on the final position, then sample.
        h = self._inner.norm(h)
        logits = self._head(h[:, -1:, :])[:, -1, :]  # [1, vocab]
        token = self._sample(logits, sample, temperature, top_p)
        return "token", token

    @staticmethod
    def _sample(logits: Any, sample: bool, temperature: float, top_p: float) -> int:
        import mlx.core as mx

        if not sample or temperature <= 0:
            return int(mx.argmax(logits, axis=-1).reshape(-1)[0].item())

        from mlx_lm.sample_utils import make_sampler

        logprobs = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
        sampler = make_sampler(temp=temperature, top_p=top_p)
        return int(sampler(logprobs).reshape(-1)[0].item())
