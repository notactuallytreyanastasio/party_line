import random

from party_line_harness.persona import Persona
from party_line_harness.urge import compute_urge

NOVA = Persona(
    name="Nova",
    prime_directive="You are Nova.",
    interests=["raccoons", "synthesizers"],
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
