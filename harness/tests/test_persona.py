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
