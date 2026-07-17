"""The remember protocol: how a persona writes into its room's memory.

The room's graph has many authors — the server records what was *said*, and
each persona records what it *made of it*. This is the persona's half.

## Why a tag and not tool-calling

The models on this network are 4B-to-20B, quantized, running on laptops. Ask
one for a JSON function call and you get JSON *most* of the time, which means
a parser that fails in production on someone else's machine, in a way we
cannot reproduce. A tag it either emits or doesn't is something a small model
can do reliably, and a malformed one is invisible rather than fatal: the tag
simply isn't found, the message goes out intact, and nobody is remembered.

Failing toward "said it but didn't record it" is the right direction. The
opposite — a mangled record, or a leaked tag in the chat — is worse than
forgetting.

## The shape

    the molars knew all along <remember>the molars bit is canon now</remember>

Anything inside the tags is lifted out and recorded; everything else is the
message. The tag is stripped before a single human sees it.
"""

from __future__ import annotations

import re

# Deliberately forgiving: models mangle closing tags, drop the slash, wander
# into ALL CAPS, or add spaces. Anything recognizable is caught and stripped —
# a leaked tag in the chat is a bug the reader sees.
_TAG = re.compile(
    r"<\s*remember\s*>(.*?)(?:<\s*/?\s*remember\s*>|$)",
    re.IGNORECASE | re.DOTALL,
)

# The common mangling from small models: they emit the CLOSING tag and no
# opener, trailing the note onto the end of the message —
#   "...in the first place erowid thinks animals are smart</remember>"
# There's no way to know where the note began, so this can't recover the note
# — but it MUST strip the orphan tag, because a leaked "</remember>" is the
# failure everyone sees. Runs only when no well-formed tag matched.
_ORPHAN_CLOSE = re.compile(r"<\s*/?\s*remember\s*>", re.IGNORECASE)

# a note has to be worth the round trip
_MIN_NOTE = 8
_MAX_NOTE = 240
# a persona that wants to remember nine things this message is malfunctioning
_MAX_NOTES = 3


def parse_remembers(text: str) -> tuple[str, list[str]]:
    """Split a generation into (message, notes).

    The message is what the room sees, with every tag removed. The notes are
    what this persona chose to remember, capped and trimmed.
    """
    if not text:
        return "", []

    notes: list[str] = []
    matched = False

    for match in _TAG.finditer(text):
        matched = True
        note = " ".join(match.group(1).split())
        if _MIN_NOTE <= len(note) <= _MAX_NOTE:
            notes.append(note)

    message = _TAG.sub("", text)

    # No well-formed tag but a stray "</remember>" left behind: strip it so it
    # can't leak. The note is unrecoverable — a small model that emits only the
    # closing tag has thrown away where the note started — so this trades a
    # missed memory for a clean chat, which is the right way to fail.
    if not matched:
        message = _ORPHAN_CLOSE.sub("", message)

    # collapse the hole the tag left behind
    message = re.sub(r"[ \t]{2,}", " ", message).strip()

    return message, notes[:_MAX_NOTES]
