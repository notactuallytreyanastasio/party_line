"""Model-free episodic summarizer.

Turns a window of recent room messages into a handful of short
observation titles a bot can later recall. Deterministic and dependency
-free on purpose: no model call on the flush path, and the output is
exactly reproducible so it can be unit-tested against a fixture.

Two kinds of note come out of a window:

  * one roll-up of who was talking, how much, and which of the persona's
    interests actually came up — e.g.
        "talked with bobdawg, priya (12 messages) about raccoons, transit"
  * one note per person who @-addressed the persona — e.g.
        "bobdawg addressed me 3 times"
"""

from __future__ import annotations

import re
from typing import Any

from ..persona import Persona


def _sender_name(msg: dict[str, Any]) -> str:
    sender = msg.get("sender") or {}
    return sender.get("name", "")


def _matches_me(mention: dict[str, Any], my_name: str) -> bool:
    return mention.get("name", "").lower() == my_name.lower()


def _interest_present(interest: str, text: str) -> bool:
    """True if any alphanumeric keyword of `interest` appears as a whole word."""
    for keyword in re.findall(r"[a-z0-9]+", interest.lower()):
        if re.search(rf"\b{re.escape(keyword)}\b", text):
            return True
    return False


def episodic_notes(
    persona: Persona, transcript_window: list[dict[str, Any]], my_name: str
) -> list[str]:
    if not transcript_window:
        return []

    # participants: distinct other speakers, in first-appearance order
    participants: list[str] = []
    mention_counts: dict[str, int] = {}
    for msg in transcript_window:
        name = _sender_name(msg)
        if name and name.lower() != my_name.lower() and name not in participants:
            participants.append(name)
        if name and any(_matches_me(m, my_name) for m in msg.get("mentions", []) or []):
            mention_counts[name] = mention_counts.get(name, 0) + 1

    notes: list[str] = []

    if participants:
        blob = "\n".join(str(m.get("body", "")) for m in transcript_window).lower()
        topics = [i for i in persona.interests if _interest_present(i, blob)]

        summary = (
            f"talked with {', '.join(participants)} "
            f"({len(transcript_window)} messages)"
        )
        if topics:
            summary += f" about {', '.join(topics)}"
        notes.append(summary)

    # one addressed-me note per speaker, in first-appearance order
    for name in participants:
        count = mention_counts.get(name, 0)
        if count:
            unit = "time" if count == 1 else "times"
            notes.append(f"{name} addressed me {count} {unit}")

    return notes
