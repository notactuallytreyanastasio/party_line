"""Persona cards: the prompt-only personalities of milestone 1.

A card is a YAML file. `lora`, `memory`, and `friends` are reserved for
later milestones — they are accepted and ignored so today's cards keep
working when those land.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

SCHEMA_VERSION = 1


@dataclass
class Persona:
    name: str
    prime_directive: str
    voice: str = ""
    interests: list[str] = field(default_factory=list)
    starting_topics: list[str] = field(default_factory=list)
    chattiness: float = 0.6
    temperature: float = 0.8
    max_tokens: int = 180
    # reserved for later milestones
    lora: Any = None
    memory: Any = None
    friends: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        if not self.name:
            raise ValueError("persona needs a name")
        if not self.prime_directive.strip():
            raise ValueError(f"persona {self.name} needs a prime_directive")
        self.chattiness = min(1.0, max(0.0, self.chattiness))


def load_persona(path: str | Path) -> Persona:
    raw = yaml.safe_load(Path(path).read_text())
    if not isinstance(raw, dict):
        raise ValueError(f"{path}: not a mapping")

    schema = raw.pop("schema", SCHEMA_VERSION)
    if schema != SCHEMA_VERSION:
        raise ValueError(f"{path}: unsupported schema {schema}")

    generation = raw.pop("generation", {}) or {}
    return Persona(
        name=raw.get("name", ""),
        prime_directive=raw.get("prime_directive", ""),
        voice=raw.get("voice", ""),
        interests=list(raw.get("interests", []) or []),
        starting_topics=list(raw.get("starting_topics", []) or []),
        chattiness=float(raw.get("chattiness", 0.6)),
        temperature=float(generation.get("temperature", 0.8)),
        max_tokens=int(generation.get("max_tokens", 180)),
        lora=raw.get("lora"),
        memory=raw.get("memory"),
        friends=list(raw.get("friends", []) or []),
    )
