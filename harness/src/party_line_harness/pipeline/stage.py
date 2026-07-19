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

import numpy as np

from .shard import Shard, parse_stage_spec


def _trunk(model: Any) -> Any:
    """The transformer trunk that holds ``embed_tokens`` / ``layers`` / ``norm``.
    mlx-lm wraps it as ``model.model`` for the Llama/Qwen/Mistral/Gemma families."""
    inner = getattr(model, "model", None)
    if inner is None or not hasattr(inner, "layers"):
        raise ValueError("unsupported model: no .model trunk with .layers")
    return inner


class PipelineStage:
    """A loaded shard, ready to run its slice of the forward pass.

    Stateful across a generation: KV caches accumulate per ``session`` id, so
    ``reset(session)`` before a fresh prompt.
    """

    def __init__(self, model: Any, shard: Shard, *, layer_offset: int | None = None):
        # where this shard's layers begin in ``model.model.layers``: ``shard.start``
        # when the model is the whole thing (shared across in-process stages), or
        # 0 when the model has been pruned to just this shard (``load``).
        offset = shard.start if layer_offset is None else layer_offset
        self.model = model
        self.shard = shard
        self._inner = _trunk(model)
        self._cache_range = (offset, offset + shard.n_local)
        self._layers = list(self._inner.layers)[offset : offset + shard.n_local]
        # the *activation* dtype (fp16/bf16), read off the final RMSNorm weight —
        # NOT embed_tokens.weight, which on a quantized model is packed uint32
        # and would corrupt a hidden state cast to it.
        self._dtype = self._inner.norm.weight.dtype
        # a sliding-window model (e.g. gemma) needs a second, windowed mask for
        # its sliding layers; a plain causal model leaves this off.
        self._sliding_window = getattr(self._inner, "sliding_window", None)
        self._has_sliding = any(getattr(l, "use_sliding", False) for l in self._layers)
        self._head = self._resolve_head(model)
        self._caches: dict[str, list] = {}

    @classmethod
    def load(cls, model_id: str, stage_spec: str) -> "PipelineStage":
        """Load **only this shard's weights**, so a machine holds a fraction of
        the model, not the whole thing.

        The model is loaded lazily (weights are memory-mapped, nothing in RAM),
        pruned to the shard's layers, and only the tensors this shard actually
        runs are materialized: its layer block + the final norm, plus the token
        embedding on the first shard and the lm_head on the last. Everything
        else stays an un-evaluated mmap and never costs memory. Hosting layers
        16–31 of an 8B costs ~1.3 GB, not the full ~4.5 GB.
        """
        import mlx.core as mx
        from mlx_lm import load

        model, _ = load(model_id, lazy=True)
        inner = _trunk(model)
        shard = parse_stage_spec(stage_spec, len(inner.layers))

        # drop references to the layers this shard doesn't run; the pruned model's
        # layers are now 0-indexed, so the stage runs at layer_offset 0.
        inner.layers = inner.layers[shard.start : shard.end + 1]

        # materialize only what this shard touches — never the far endpoint.
        keep: list[Any] = [layer.parameters() for layer in inner.layers]
        keep.append(inner.norm.parameters())
        if shard.has_embed:
            keep.append(inner.embed_tokens.parameters())
        if shard.has_head:
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

    def reset(self, session: str) -> None:
        self._caches.pop(session, None)

    def _cache_for(self, session: str) -> list:
        cache = self._caches.get(session)
        if cache is None:
            # the model builds the right cache type per layer (rotating for
            # sliding layers, plain KV otherwise); take just this shard's slice.
            lo, hi = self._cache_range
            cache = self.model.make_cache()[lo:hi]
            self._caches[session] = cache
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
