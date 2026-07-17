import random

import pytest

from party_line_harness.persona import Persona
from party_line_harness.urge import ADDRESSED_ELSEWHERE_URGE, compute_urge

NOVA = Persona(
    name="Nova",
    prime_directive="You are Nova.",
    interests=["raccoons", "synthesizers"],
    chattiness=0.6,
)

# the repo convention: persona names are multi-word lowercase shitposter
# handles — the mention parser and continuation check must handle them
SMOOTHIE = Persona(
    name="erowid smoothie",
    prime_directive="You blend things.",
    interests=["kava", "gas station supplements"],
    chattiness=0.6,
)

HORSE = Persona(
    name="Horse Dentist",
    prime_directive="You look at teeth.",
    interests=["teeth"],
    chattiness=0.6,
)

SERVER_THRESHOLD = 0.2


def msg(sender, body, mentions=(), kind="human"):
    return {
        "sender": {"name": sender, "kind": kind},
        "body": body,
        "mentions": [{"name": m} for m in mentions],
    }


def test_mentioned_means_high_urge():
    t = [msg("Bobby", "@Nova what do you think?", mentions=["Nova"])]
    assert compute_urge(NOVA, t) == 0.95


def test_mention_match_is_case_insensitive():
    t = [msg("Bobby", "@nova?", mentions=["nova"])]
    assert compute_urge(NOVA, t) == 0.95


def test_continuation_urge_is_moderate_never_dominant():
    # a bot that just spoke may want to continue — but never at summons level,
    # and the server's fairness damp is what keeps runs in check
    t = [msg("Nova", "as I was saying", kind="bot")]
    for seed in range(20):
        u = compute_urge(NOVA, t, rng=random.Random(seed))
        assert 0.0 <= u < 0.6


def test_message_addressed_to_someone_else_stays_below_threshold():
    # the milestone criterion: human→human @ messages draw no qualifying bids
    t = [msg("Bobby", "@Priya did you see the coyote thing?", mentions=["Priya"])]
    assert compute_urge(NOVA, t) < SERVER_THRESHOLD


def test_empty_room_gets_opened():
    assert compute_urge(NOVA, []) > SERVER_THRESHOLD


def test_open_conversation_can_clear_threshold():
    t = [msg("Bobby", "raccoons got into my synthesizers again")]
    rng = random.Random(7)
    samples = [compute_urge(NOVA, t, rng=rng) for _ in range(20)]
    assert max(samples) > SERVER_THRESHOLD


def test_silence_pressure_builds():
    t = [msg("Bobby", "well."), ]
    rng = random.Random(7)
    quiet = compute_urge(NOVA, t, beats_since_message=8, rng=random.Random(7))
    fresh = compute_urge(NOVA, t, beats_since_message=0, rng=random.Random(7))
    assert quiet > fresh


def test_urge_is_clamped():
    chatty = Persona(name="X", prime_directive="x", chattiness=1.0, interests=["a"])
    t = [msg("Bobby", "a a a a")]
    for seed in range(30):
        u = compute_urge(chatty, t, beats_since_message=20, rng=random.Random(seed))
        assert 0.0 <= u <= 1.0


def test_multiword_lowercase_persona_is_summoned_case_insensitively():
    t = [msg("Bobby", "@Erowid Smoothie is this safe to drink?", mentions=["Erowid Smoothie"])]
    assert compute_urge(SMOOTHIE, t) == 0.95


def test_multiword_mention_addressed_elsewhere_stays_below_threshold():
    t = [msg("Bobby", "@erowid smoothie is this safe?", mentions=["erowid smoothie"])]
    assert compute_urge(HORSE, t) == ADDRESSED_ELSEWHERE_URGE
    assert ADDRESSED_ELSEWHERE_URGE < SERVER_THRESHOLD


def test_continuation_detected_for_multiword_lowercase_name():
    warlock = Persona(name="coupon warlock", prime_directive="clip.", chattiness=0.6)
    t = [msg("coupon warlock", "and another thing about extreme couponing", kind="bot")]
    for seed in range(20):
        u = compute_urge(warlock, t, rng=random.Random(seed))
        assert 0.0 <= u < 0.6  # damped continuation, never the open-room score


def test_pressure_grows_with_messages_since_i_spoke():
    filler = [msg("Bobby", "hm"), msg("Priya", "yeah"), msg("Bobby", "sure"), msg("Priya", "ok")]
    spoke_long_ago = (
        [msg("erowid smoothie", "kombucha thoughts", kind="bot")] + filler + [msg("Bobby", "anyway")]
    )
    spoke_recently = [
        msg("erowid smoothie", "kombucha thoughts", kind="bot"),
        msg("Bobby", "anyway"),
    ]
    long_ago = compute_urge(SMOOTHIE, spoke_long_ago, rng=random.Random(11))
    recent = compute_urge(SMOOTHIE, spoke_recently, rng=random.Random(11))
    assert long_ago > recent


def test_empty_interest_list_contributes_nothing():
    plain = Persona(name="beige enjoyer", prime_directive="be beige.", chattiness=0.4, interests=[])
    t = [msg("Bobby", "kava teeth raccoons everything")]
    # chattiness*0.5 + zero overlap + msgs-since pressure (1 msg) + seeded noise
    expected = 0.4 * 0.5 + 0.05 * 1 + random.Random(5).uniform(-0.15, 0.10)
    assert compute_urge(plain, t, rng=random.Random(5)) == pytest.approx(expected)
