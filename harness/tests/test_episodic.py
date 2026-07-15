"""The model-free episodic summarizer is deterministic — pin it to fixtures."""

from __future__ import annotations

from party_line_harness.memory.episodic import episodic_notes
from party_line_harness.persona import Persona

NOVA = Persona(
    name="Nova",
    prime_directive="You are Nova.",
    interests=["raccoons", "transit", "opera"],
)


def msg(sender, body, mentions=()):
    return {
        "sender": {"name": sender, "kind": "human"},
        "body": body,
        "mentions": [{"name": n} for n in mentions],
    }


WINDOW = [
    msg("bobdawg", "the raccoons are back on the roof"),
    msg("priya", "transit was a nightmare today"),
    msg("bobdawg", "@Nova what do you think", mentions=["Nova"]),
    msg("bobdawg", "@Nova seriously though", mentions=["Nova"]),
    msg("priya", "lol"),
    msg("bobdawg", "@Nova you there?", mentions=["Nova"]),
]


def test_summary_lists_participants_count_and_present_topics():
    notes = episodic_notes(NOVA, WINDOW, "Nova")
    assert notes[0] == "talked with bobdawg, priya (6 messages) about raccoons, transit"
    # 'opera' never came up, so it isn't a topic
    assert "opera" not in notes[0]


def test_addressed_note_counts_only_the_mentioner():
    notes = episodic_notes(NOVA, WINDOW, "Nova")
    assert "bobdawg addressed me 3 times" in notes
    # priya never @-addressed me
    assert not any("priya addressed" in n for n in notes)


def test_single_mention_is_singular():
    window = [msg("bobdawg", "@Nova hi", mentions=["Nova"])]
    notes = episodic_notes(NOVA, window, "Nova")
    assert "bobdawg addressed me 1 time" in notes


def test_my_own_messages_are_not_participants():
    window = [
        msg("Nova", "I love raccoons"),
        msg("bobdawg", "same"),
    ]
    notes = episodic_notes(NOVA, window, "Nova")
    assert notes[0].startswith("talked with bobdawg (2 messages)")


def test_summary_without_topics_omits_about():
    window = [msg("bobdawg", "hey"), msg("priya", "hi")]
    notes = episodic_notes(NOVA, window, "Nova")
    assert notes == ["talked with bobdawg, priya (2 messages)"]


def test_empty_window_is_no_notes():
    assert episodic_notes(NOVA, [], "Nova") == []


def test_all_mine_yields_nothing():
    window = [msg("Nova", "talking to myself about raccoons")]
    assert episodic_notes(NOVA, window, "Nova") == []
