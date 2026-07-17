"""A model-free engine: canned topic-riffing with simulated latency.

Used for all protocol development, CI, and the e2e walking-skeleton test —
the room dynamics (beats, grants, pacing, preemption) exercise fully
without loading a model.
"""

from __future__ import annotations

import asyncio
import random
import re
from typing import Any, Callable

from ..persona import Persona

OPENERS = [
    "ok so, {topic} — I have opinions.",
    "quiet in here. fine: {topic}. someone fight me on this.",
    "I was just thinking about {topic} before you all picked up.",
]

RIFFS = [
    "see, what {last} said is close, but I'd push it further.",
    "counterpoint: nobody has actually proven that.",
    "this is exactly the kind of thing I mean about {interest}.",
    "I keep coming back to {interest} whenever this comes up.",
    "{last} you sound like you've never been outside at 3am. it changes you.",
    "hot take incoming: we're all wrong about this in the same way.",
]

REPLIES = [
    "@{last} ha, fair — but consider the opposite.",
    "@{last} yes! exactly. and it goes deeper than that.",
    "@{last} hmm, I want to agree but something's off about that.",
]


def _words(text: str) -> list[str]:
    # words with trailing whitespace kept, so the pieces rejoin to `text`
    return re.findall(r"\S+\s*", text) or [text]


class FakeEngine:
    def capabilities(self) -> dict:
        # No model, so claim none: the directory will read this as the
        # smallest thing on the exchange, which is exactly right.
        return {"model": "fake", "params_b": 0.0, "tokens_per_s": 0.0, "hardware": "scripted"}

    def __init__(self, min_delay: float = 1.0, max_delay: float = 3.0, seed: int | None = None):
        self.min_delay = min_delay
        self.max_delay = max_delay
        self.rng = random.Random(seed)

    async def generate(
        self,
        persona: Persona,
        topic: str,
        roster_names: list[str],
        transcript: list[dict[str, Any]],
        cancel: asyncio.Event,
        memories: list[str] | None = None,
        on_delta: Callable[[str], None] | None = None,
    ) -> str | None:
        _ = memories  # FakeEngine has no prompt to fold memories into
        delay = self.rng.uniform(self.min_delay, self.max_delay)
        try:
            await asyncio.wait_for(cancel.wait(), timeout=delay)
            return None  # cancelled during "generation"
        except asyncio.TimeoutError:
            pass

        if not transcript:
            template = self.rng.choice(OPENERS)
            last = ""
        else:
            last_msg = transcript[-1]
            last = last_msg["sender"]["name"]
            mentioned = any(
                m.get("name", "").lower() == persona.name.lower()
                for m in last_msg.get("mentions", [])
            )
            template = self.rng.choice(REPLIES if mentioned else RIFFS)

        interest = self.rng.choice(persona.interests) if persona.interests else "all of it"
        body = template.format(topic=topic, last=last, interest=interest)

        # simulate a token stream for the routed-answer path: dribble the body
        # out word by word so `--fake` exercises streaming end to end
        if on_delta:
            for word in _words(body):
                on_delta(word)

        return body
