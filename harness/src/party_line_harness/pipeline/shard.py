"""How a model's layers are split across pipeline stages.

A model with ``n_layers`` transformer blocks is cut into ``count`` contiguous
shards. Whoever holds layer 0 also owns the token embedding; whoever holds the
last layer owns the final norm + lm_head. Everything here is pure arithmetic —
no MLX, no model — so it is unit-tested directly.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Shard:
    """A contiguous block of transformer layers ``[start, end]`` (inclusive),
    positioned as stage ``index`` of ``count`` in the pipeline.

    ``has_embed``/``has_head`` decide which extra pieces this stage runs: the
    embedding hangs off layer 0, the final norm + lm_head off the last layer.
    """

    start: int
    end: int
    n_layers: int
    index: int
    count: int

    def __post_init__(self) -> None:
        if self.n_layers < 1:
            raise ValueError("n_layers must be >= 1")
        if not 0 <= self.start <= self.end < self.n_layers:
            raise ValueError(f"bad layer range {self.start}:{self.end} for {self.n_layers} layers")
        if not 0 <= self.index < self.count:
            raise ValueError(f"bad stage {self.index}/{self.count}")

    @property
    def n_local(self) -> int:
        """How many layers this stage actually runs."""
        return self.end - self.start + 1

    @property
    def has_embed(self) -> bool:
        """The first shard turns token ids into hidden states."""
        return self.start == 0

    @property
    def has_head(self) -> bool:
        """The last shard applies the final norm + lm_head and samples."""
        return self.end == self.n_layers - 1

    @property
    def is_first(self) -> bool:
        return self.index == 0

    @property
    def is_last(self) -> bool:
        return self.index == self.count - 1

    @property
    def label(self) -> str:
        return f"stage {self.index}/{self.count} layers {self.start}-{self.end}"


def partition_layers(n_layers: int, count: int) -> list[Shard]:
    """Split ``n_layers`` into ``count`` contiguous shards, as even as possible
    with the remainder handed to the earliest stages. ``count`` must not exceed
    ``n_layers`` (an empty stage has nothing to compute)."""
    if n_layers < 1:
        raise ValueError("n_layers must be >= 1")
    if count < 1:
        raise ValueError("count must be >= 1")
    if count > n_layers:
        raise ValueError(f"cannot split {n_layers} layers across {count} stages")

    base, extra = divmod(n_layers, count)
    shards: list[Shard] = []
    start = 0
    for i in range(count):
        size = base + (1 if i < extra else 0)
        end = start + size - 1
        shards.append(Shard(start=start, end=end, n_layers=n_layers, index=i, count=count))
        start = end + 1
    return shards


def parse_stage_spec(spec: str, n_layers: int) -> Shard:
    """Resolve a CLI stage spec against a model's layer count.

    Two forms:

      * ``"i/n"`` — stage ``i`` of an even ``n``-way split (0-indexed).
      * ``"a:b"`` — an explicit inclusive layer range (this stage is treated as
        a lone stage 0/1, so it owns both embed and head unless the range is a
        strict interior slice — used for hand-driven experiments).

    The ``i/n`` form is the one the driver and ``serve-shard`` agree on.
    """
    spec = spec.strip()
    if "/" in spec:
        i_s, n_s = spec.split("/", 1)
        index, count = int(i_s), int(n_s)
        return partition_layers(n_layers, count)[index]
    if ":" in spec:
        a_s, b_s = spec.split(":", 1)
        start, end = int(a_s), int(b_s)
        return Shard(start=start, end=end, n_layers=n_layers, index=0, count=1)
    raise ValueError(f"stage spec must be 'i/n' or 'a:b', got {spec!r}")
