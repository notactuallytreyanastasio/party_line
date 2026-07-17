from pathlib import Path

import pytest

from party_line_harness.persona import Persona, load_persona

CARDS = Path(__file__).resolve().parents[2] / "personas"


def test_ships_six_valid_cards():
    cards = sorted(CARDS.glob("*.yaml"))
    assert len(cards) == 6
    personas = [load_persona(c) for c in cards]

    assert {p.name for p in personas} == {
        "Horse Dentist",
        "erowid smoothie",
        "DigimonOtis",
        "Beef Inspector",
        "coupon warlock",
        "mothman apologist",
    }
    for p in personas:
        assert p.prime_directive.strip()
        assert 0.0 <= p.chattiness <= 1.0
        assert p.interests
        assert p.starting_topics


def test_generation_settings_load():
    card = load_persona(CARDS / "erowid_smoothie.yaml")
    assert card.temperature == 0.9
    assert card.max_tokens == 160


def test_reserved_keys_are_tolerated():
    card = load_persona(CARDS / "horse_dentist.yaml")
    assert card.lora is None
    assert card.friends == []


def test_missing_directive_rejected(tmp_path):
    bad = tmp_path / "bad.yaml"
    bad.write_text("schema: 1\nname: Ghost\n")
    with pytest.raises(ValueError):
        load_persona(bad)


def test_chattiness_clamped():
    p = Persona(name="X", prime_directive="x", chattiness=3.0)
    assert p.chattiness == 1.0


def test_chattiness_clamped_from_below():
    p = Persona(name="X", prime_directive="x", chattiness=-2.0)
    assert p.chattiness == 0.0


def test_empty_name_rejected():
    with pytest.raises(ValueError, match="needs a name"):
        Persona(name="", prime_directive="x")


def test_non_mapping_card_rejected(tmp_path):
    bad = tmp_path / "list.yaml"
    bad.write_text("- just\n- a list\n")
    with pytest.raises(ValueError) as excinfo:
        load_persona(bad)
    assert str(bad) in str(excinfo.value)


def test_future_schema_rejected(tmp_path):
    card = tmp_path / "future.yaml"
    card.write_text("schema: 2\nname: ghost freak\nprime_directive: haunt politely.\n")
    with pytest.raises(ValueError, match="unsupported schema"):
        load_persona(card)
