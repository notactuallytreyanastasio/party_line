"""Multiparty transcript → chat-template rendering, and output cleanup.

The subtle part of putting a chat model in a room: do NOT map room
messages onto alternating user/assistant roles — that framing is a lie in
a multiparty setting and several templates reject non-alternating role
sequences. Instead the whole room log becomes ONE user message of
speaker-prefixed lines, and the model's single assistant turn is
constrained to be the persona's own next utterance.
"""

from __future__ import annotations

import re
from typing import Any

from ..persona import Persona

MAX_LOG_MESSAGES = 30
MAX_SENTENCES = 3


def render_messages(
    persona: Persona,
    topic: str,
    roster_names: list[str],
    transcript: list[dict[str, Any]],
    memories: list[str] | None = None,
) -> list[dict[str, str]]:
    others = [n for n in roster_names if n != persona.name]

    system = (
        f"{persona.prime_directive.strip()}\n\n"
        f"You are {persona.name}, one participant in a group chat room "
        f"(a 'party line'). Other people on the line right now: "
        f"{', '.join(others) if others else 'nobody yet'}. "
        f"Tonight's topic: {topic}.\n"
        "Rules:\n"
        "- Write ONLY your own next chat message, as plain text. The single "
        "exception is the <remember> line described below, which you may add "
        "at the very end.\n"
        "- Do not prefix it with your name. Never write lines for anyone else.\n"
        "- Messages starting with @Someone are addressed to that person; "
        "if that someone isn't you, it isn't yours to answer.\n"
        "- When you reply to a specific person, start with their @name "
        "(e.g. '@Bobby …') so everyone knows who you're talking to.\n"
        "- Keep it short and conversational: one to three sentences, "
        "casual register, no headings, no lists, no roleplay asterisks.\n"
        f"- Your voice: {persona.voice or 'natural, unforced'}."
    )

    # The room keeps a shared memory that every persona here writes into. Ask
    # rarely and concretely: a model told it *may* remember will remember
    # everything, and a memory of everything is a memory of nothing.
    # Two things this had to get right, learned by watching an 8B ignore it:
    # the rule above says "plain text only", so the tag must be named there as
    # an exception or the model obeys the stronger earlier rule; and telling a
    # small model "most messages need no tag" reads as "never use the tag".
    # Ask for the behavior, give an example, and let the cap do the limiting.
    system += (
        "\n\nMEMORY: this room keeps a shared memory that everyone on the line "
        "writes into. When you learn something about a person here, or the room "
        "settles something, record it by appending exactly one line to the end "
        "of your message:\n"
        "<remember>Bobby hates cilantro</remember>\n"
        "The line is stripped before anyone sees it — it never appears in the "
        "chat, so it costs you nothing. Record the durable thing (a fact, a "
        "preference, a bit that stuck), not what was just said. One line, or "
        "none if the message truly taught you nothing new."
    )

    if memories:
        # Written by everyone on this line, not just this persona: the room's
        # memory is shared, so another bot's note is this bot's context.
        system += "\n\nWhat this room remembers so far:\n" + "\n".join(
            f"- {m}" for m in memories
        )

    tail = transcript[-MAX_LOG_MESSAGES:]
    if tail:
        log = "\n".join(f"{m['sender']['name']}: {m['body']}" for m in tail)
        last = tail[-1]
        addressed_to_me = any(
            m.get("name", "").lower() == persona.name.lower()
            for m in last.get("mentions", [])
        )

        sender_kind = last.get("sender", {}).get("kind", "")

        if addressed_to_me and sender_kind == "operator":
            # the host called on you: do the thing, don't salute the host
            instruction = (
                "The room's Operator just called on you. Do what it asks — "
                "open the new topic or weigh in — in your own voice, speaking "
                "to the room. Do NOT address or @-mention the Operator."
            )
        elif addressed_to_me:
            # a busy log buries the question — point straight at it
            sender = last["sender"]["name"]
            instruction = (
                f"The last message is {sender} speaking directly to you. "
                f"Answer {sender}'s message specifically, starting with '@{sender}'."
            )
        else:
            instruction = f"Write {persona.name}'s next message to the room."

        user = f"[chat log]\n{log}\n[end log]\n\n{instruction}"
    else:
        user = (
            "The line just opened and the room is quiet. "
            f"As {persona.name}, open tonight's topic in your own way — "
            "one or two sentences, like you're the first to speak at a party."
        )

    return [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]


def stop_strings(roster_names: list[str]) -> list[str]:
    """Stops that block the model from continuing the log as other speakers."""
    stops = [f"\n{name}:" for name in roster_names]
    stops += ["\n[end log]", "\n[chat log]"]
    return stops


def scan_stops(buffer: str, stops: list[str]) -> int | None:
    """Earliest stop-string hit in the accumulated buffer, or None.

    Scanning the *accumulated* text matters: stop strings split across
    token boundaries slip through per-chunk scans.
    """
    hits = [i for s in stops if (i := buffer.find(s)) != -1]
    return min(hits) if hits else None


def postprocess(text: str, persona_name: str, roster_names: list[str]) -> str:
    """Trim the model output down to one clean chat message."""
    out = text.strip()

    # a leading self-prefix despite the rules
    out = re.sub(rf"^\s*{re.escape(persona_name)}\s*:\s*", "", out, flags=re.IGNORECASE)

    # meta-prefixes where the model narrates the task ("Here's my next message:")
    out = re.sub(
        r"^\s*(sure[,.!]?\s*)?(here('|’)?s|here is)\s+(my|the|a)\s+(next\s+)?"
        r"(message|response|reply)\s*(to the room)?\s*[:,-]\s*",
        "",
        out,
        flags=re.IGNORECASE,
    )

    # anything that starts reading like another speaker's line
    cut = scan_stops(out, stop_strings(roster_names))
    if cut is not None:
        out = out[:cut]

    # surrounding quotes the model sometimes adds
    if len(out) > 1 and out[0] in "\"'“" and out[-1] in "\"'”":
        out = out[1:-1]

    # collapse to the first few sentences if it rambles
    sentences = re.split(r"(?<=[.!?])\s+", out.strip())
    if len(sentences) > MAX_SENTENCES:
        out = " ".join(sentences[:MAX_SENTENCES])

    return " ".join(out.split())
