"""Natural pacing: a message should land on human typing timescales.

Generation latency counts toward the typing time, so on real hardware the
extra sleep is usually near zero for long messages — the model's own
slowness *is* the realism.
"""

from __future__ import annotations

import random

BASE_DELAY_S = 1.0
CHARS_PER_SECOND = 25.0


def typing_delay(body: str, elapsed_generation_s: float, rng: random.Random | None = None) -> float:
    rng = rng or random.Random()
    target = BASE_DELAY_S + len(body) / CHARS_PER_SECOND + rng.uniform(0.0, 0.8)
    return max(0.0, target - elapsed_generation_s)
