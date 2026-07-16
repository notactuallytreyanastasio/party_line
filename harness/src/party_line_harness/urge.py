"""Urge-to-speak scoring.

A pure function over the transcript tail — no model call, which is why a
1.5-second bid window is comfortable. The server applies its own fairness
layer on top, so these numbers only need to be honest, not adversarial.

The load-bearing rule for the milestone: a message that @-mentions someone
who isn't me scores 0.05, below the server's 0.20 threshold — bots stay
out of human→human (and bot→bot) addressed exchanges.
"""

from __future__ import annotations

import random
import re
from typing import Any

from .persona import Persona

MENTIONED_URGE = 0.95
ADDRESSED_ELSEWHERE_URGE = 0.05


def compute_urge(
    persona: Persona,
    transcript: list[dict[str, Any]],
    *,
    beats_since_message: int = 0,
    msgs_since_i_spoke: int | None = None,
    rng: random.Random | None = None,
) -> float:
    rng = rng or random.Random()

    if not transcript:
        # quiet room: somebody has to open the topic
        return _clamp(0.55 + 0.35 * persona.chattiness)

    last = transcript[-1]
    mentions = [m.get("name", "") for m in last.get("mentions", [])]

    if last.get("sender", {}).get("name") == persona.name:
        # continuation: a leading voice may keep developing its thought —
        # the server dampens and caps runs, so this only wins when nobody
        # else is eager (chattier personas hold the floor longer)
        return _clamp(persona.chattiness * 0.55 + (rng.uniform(-0.1, 0.1)))
    if any(name.lower() == persona.name.lower() for name in mentions):
        return MENTIONED_URGE
    if mentions:
        return ADDRESSED_ELSEWHERE_URGE

    if msgs_since_i_spoke is None:
        msgs_since_i_spoke = _msgs_since_i_spoke(persona.name, transcript)

    urge = (
        persona.chattiness * 0.5
        + 0.2 * _interest_overlap(persona, transcript[-4:])
        + min(0.25, 0.05 * msgs_since_i_spoke)
        + rng.uniform(-0.15, 0.10)
    )

    # a long-quiet room builds pressure on the chattier personas to revive it
    if beats_since_message > 2:
        urge += 0.1 * beats_since_message * persona.chattiness

    return _clamp(urge)


def _msgs_since_i_spoke(name: str, transcript: list[dict[str, Any]]) -> int:
    count = 0
    for message in reversed(transcript):
        if message.get("sender", {}).get("name") == name:
            return count
        count += 1
    return count


def _interest_overlap(persona: Persona, tail: list[dict[str, Any]]) -> float:
    if not persona.interests:
        return 0.0
    text = " ".join(m.get("body", "") for m in tail).lower()
    words = set(re.findall(r"[a-z']+", text))
    hits = sum(
        1
        for interest in persona.interests
        if any(token in words for token in interest.lower().split())
    )
    return min(1.0, hits / max(1, len(persona.interests)) * 2)


def _clamp(x: float) -> float:
    return max(0.0, min(1.0, x))
