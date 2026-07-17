import sys

import pytest

from party_line_harness import serve_llm
from party_line_harness.main import assign_rooms, cli, slug


def test_no_flag_defaults_all():
    assert assign_rooms(3, None) == [None, None, None]


def test_single_room_applies_to_all():
    assert assign_rooms(3, "room-x") == ["room-x"] * 3


def test_one_per_persona_in_order():
    assert assign_rooms(2, "room-a, room-b") == ["room-a", "room-b"]


def test_mismatched_count_exits():
    with pytest.raises(SystemExit):
        assign_rooms(3, "room-a,room-b")


# ── slug: shitposter handle → per-bot memory graph id ────────────────────────


def test_slug_multiword_lowercase_handle():
    assert slug("erowid smoothie") == "erowid-smoothie"


def test_slug_lowercases_capitalized_handles():
    assert slug("Horse Dentist") == "horse-dentist"


def test_slug_drops_punctuation_keeps_underscores_and_hyphens():
    assert slug("mothman's #1 fan_club-forever!") == "mothmans-1-fan_club-forever"


# ── cli dispatch and guards ──────────────────────────────────────────────────


def _card(tmp_path, filename, name):
    path = tmp_path / filename
    path.write_text(f"schema: 1\nname: {name}\nprime_directive: post through it.\n")
    return str(path)


def test_cli_rejects_duplicate_persona_names_case_insensitively(tmp_path, monkeypatch):
    one = _card(tmp_path, "one.yaml", "Horse Dentist")
    two = _card(tmp_path, "two.yaml", "horse dentist")
    monkeypatch.setattr(sys, "argv", ["party-line-harness", one, two, "--engine", "fake"])

    # the duplicate check fires before asyncio.run — no network is touched
    with pytest.raises(SystemExit) as excinfo:
        cli()
    assert excinfo.value.code == "persona names must be unique on one harness"


def test_cli_serve_llm_dispatches_to_daemon_main(monkeypatch):
    seen = {}

    def fake_serve_main(argv):
        seen["argv"] = argv
        return 7

    monkeypatch.setattr(serve_llm, "main", fake_serve_main)
    monkeypatch.setattr(sys, "argv", ["party-line-harness", "serve-llm", "--no-tailscale"])

    with pytest.raises(SystemExit) as excinfo:
        cli()
    assert excinfo.value.code == 7
    assert seen["argv"] == ["--no-tailscale"]
