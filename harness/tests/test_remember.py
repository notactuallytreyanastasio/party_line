"""The remember protocol.

These are mostly about mangling. The models writing these tags are small,
quantized, and running on someone else's laptop — the parser's job is to catch
what they actually emit and, when it can't, to leave the message alone rather
than leak a tag into the room.
"""

from party_line_harness.memory.remember import parse_remembers


class TestTheHappyShape:
    def test_lifts_the_note_and_strips_the_tag(self):
        message, notes = parse_remembers(
            "the molars knew all along <remember>the molars bit is canon now</remember>"
        )
        assert message == "the molars knew all along"
        assert notes == ["the molars bit is canon now"]

    def test_a_message_with_no_tag_is_untouched(self):
        message, notes = parse_remembers("just talking here")
        assert message == "just talking here"
        assert notes == []

    def test_several_notes_are_all_lifted(self):
        message, notes = parse_remembers(
            "<remember>bobby hates cilantro</remember>ok noted"
            "<remember>the raccoon bit is canon</remember>"
        )
        assert message == "ok noted"
        assert len(notes) == 2

    def test_a_note_spanning_lines_is_flattened(self):
        _, notes = parse_remembers("hi <remember>bobby\n  hates\n  cilantro</remember>")
        assert notes == ["bobby hates cilantro"]


class TestWhenTheModelManglesIt:
    """A small model will get this wrong. It must fail toward silence."""

    def test_a_missing_closing_tag_still_strips(self):
        message, notes = parse_remembers("said it <remember>the bit is canon now")
        assert "<remember>" not in message, "a leaked tag is a bug the room sees"
        assert message == "said it"
        assert notes == ["the bit is canon now"]

    def test_the_orphan_closing_tag_a_real_8b_actually_emitted(self):
        # observed in the wild: gemma/llama trail the note onto the end and
        # close with </remember>, no opener. The note is unrecoverable, but the
        # tag must not reach the room.
        raw = (
            "maybe our rules are social constructs erowid smoothie thinks "
            "animals challenge our understanding</remember>"
        )
        message, notes = parse_remembers(raw)
        assert "remember" not in message.lower()
        assert message.endswith("understanding")
        assert notes == []

    def test_a_closing_tag_without_the_slash_still_strips(self):
        message, notes = parse_remembers("said it <remember>the bit is canon<remember>")
        assert "remember" not in message
        assert notes == ["the bit is canon"]

    def test_shouting_and_spacing_are_tolerated(self):
        message, notes = parse_remembers("hi < REMEMBER >bobby hates cilantro</ remember >")
        assert message == "hi"
        assert notes == ["bobby hates cilantro"]

    def test_an_empty_tag_records_nothing_and_leaves_no_trace(self):
        message, notes = parse_remembers("nothing to say here <remember></remember>")
        assert message == "nothing to say here"
        assert notes == []

    def test_a_note_too_short_to_be_worth_it_is_dropped(self):
        _, notes = parse_remembers("hm <remember>ok</remember>")
        assert notes == []

    def test_a_runaway_note_is_dropped_rather_than_stored(self):
        _, notes = parse_remembers(f"hi <remember>{'x' * 500}</remember>")
        assert notes == []

    def test_a_persona_remembering_nine_things_is_capped(self):
        text = "hi" + "".join(f"<remember>fact number {i} here</remember>" for i in range(9))
        _, notes = parse_remembers(text)
        assert len(notes) == 3

    def test_empty_input_is_not_a_crash(self):
        assert parse_remembers("") == ("", [])


class TestTheMessageSurvives:
    def test_the_hole_the_tag_left_is_collapsed(self):
        message, _ = parse_remembers("before <remember>a note worth keeping</remember> after")
        assert message == "before after"

    def test_a_message_that_was_only_a_tag_becomes_empty(self):
        # the caller decides what to do with this: nothing worth saying
        message, notes = parse_remembers("<remember>a note worth keeping</remember>")
        assert message == ""
        assert notes == ["a note worth keeping"]
