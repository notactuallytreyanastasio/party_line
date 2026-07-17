"""typing_delay: room-visible pacing rules, pinned model-free.

Pure function with an injectable rng — every case computes exact values,
no sleeps anywhere.
"""

from __future__ import annotations

import random

import pytest

from party_line_harness.pacing import BASE_DELAY_S, typing_delay


def test_slow_generation_clamps_to_zero_never_negative():
    assert typing_delay("x" * 500, 1e6, random.Random(1)) == 0.0


def test_delay_grows_with_body_length():
    short = typing_delay("a" * 10, 0.0, random.Random(2))
    longer = typing_delay("a" * 200, 0.0, random.Random(2))
    assert longer > short


def test_generation_latency_is_credited_against_the_delay():
    body = "a" * 100  # target well above 2s, so the credit is exact
    fresh = typing_delay(body, 0.0, random.Random(3))
    credited = typing_delay(body, 2.0, random.Random(3))
    assert fresh > 2.0
    assert credited == pytest.approx(max(0.0, fresh - 2.0))


def test_empty_body_still_gets_at_least_the_base_delay():
    assert typing_delay("", 0.0, random.Random(4)) >= BASE_DELAY_S
