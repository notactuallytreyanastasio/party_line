"""Per-bot living memory: each persona keeps its own deciduous graph.

`client.DeciduousMemory` talks to a deciduous API daemon; `episodic`
turns a window of chat transcript into short observation titles. Both are
built so a dead or missing daemon never breaks a running bot.
"""

from __future__ import annotations

from .client import DeciduousMemory
from .episodic import episodic_notes

__all__ = ["DeciduousMemory", "episodic_notes"]
