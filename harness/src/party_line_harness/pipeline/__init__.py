"""Pipeline-parallel inference: run part of a model on one machine and the
rest on another, passing real hidden states between the stages.

A model's transformer layers are split into contiguous *shards* (``shard.py``).
Each stage loads only its shard and runs a partial forward — embed on the first
stage, the final norm + lm_head + sampling on the last, just the layer block in
between (``stage.py``). Stages talk over a length-prefixed binary frame that
carries a JSON header plus one hidden-state tensor (``wire.py``). A ``driver``
tokenizes, walks a token through the ordered stages, and detokenizes the reply
(``driver.py``); ``serve_shard.py`` exposes a single stage over HTTP, gated by
the same secret ``serve-llm`` uses.

Positions never travel on the wire: each stage keeps its own KV cache, and
because every stage advances by the same tokens in lockstep, RoPE offsets stay
identical across the pipeline. The wire only ever carries ``[batch, seq, hidden]``.
"""

from __future__ import annotations

from .shard import Shard, parse_stage_spec, partition_layers

__all__ = ["Shard", "partition_layers", "parse_stage_spec"]
