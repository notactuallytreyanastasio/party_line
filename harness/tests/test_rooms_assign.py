import pytest

from party_line_harness.main import assign_rooms


def test_no_flag_defaults_all():
    assert assign_rooms(3, None) == [None, None, None]


def test_single_room_applies_to_all():
    assert assign_rooms(3, "room-x") == ["room-x"] * 3


def test_one_per_persona_in_order():
    assert assign_rooms(2, "room-a, room-b") == ["room-a", "room-b"]


def test_mismatched_count_exits():
    with pytest.raises(SystemExit):
        assign_rooms(3, "room-a,room-b")
