from party_line_harness.inference import transcript as tr
from party_line_harness.persona import Persona

NOVA = Persona(name="Nova", prime_directive="You are Nova, a sound designer.", voice="wry")


def msg(sender, body):
    return {"sender": {"name": sender, "kind": "human"}, "body": body, "mentions": []}


def test_render_is_system_plus_single_user_message():
    messages = tr.render_messages(NOVA, "raccoons", ["Nova", "Bobby"], [msg("Bobby", "hi all")])
    assert [m["role"] for m in messages] == ["system", "user"]
    assert "Bobby: hi all" in messages[1]["content"]
    assert "Write Nova's next message" in messages[1]["content"]
    assert "You are Nova" in messages[0]["content"]
    assert "raccoons" in messages[0]["content"]


def test_empty_transcript_asks_for_an_opener():
    messages = tr.render_messages(NOVA, "raccoons", ["Nova"], [])
    assert "open tonight's topic" in messages[1]["content"]


def test_log_is_capped():
    long = [msg("Bobby", f"message {i}") for i in range(100)]
    messages = tr.render_messages(NOVA, "t", ["Nova", "Bobby"], long)
    assert "message 99" in messages[1]["content"]
    assert "message 69" not in messages[1]["content"]


def test_scan_stops_finds_earliest_across_buffer():
    stops = tr.stop_strings(["Nova", "Bobby"])
    buffer = "sure thing.\nBobby: and then I said"
    cut = tr.scan_stops(buffer, stops)
    assert buffer[:cut] == "sure thing."


def test_postprocess_strips_self_prefix_and_other_speakers():
    raw = "Nova: honestly the raccoons are winning.\nBobby: totally!"
    out = tr.postprocess(raw, "Nova", ["Nova", "Bobby"])
    assert out == "honestly the raccoons are winning."


def test_addressed_message_gets_direct_answer_instruction():
    addressed = {
        "sender": {"name": "Bobby", "kind": "human"},
        "body": "@Nova you up?",
        "mentions": [{"name": "Nova"}],
    }
    messages = tr.render_messages(NOVA, "t", ["Nova", "Bobby"], [msg("Priya", "hi"), addressed])
    assert "speaking directly to you" in messages[1]["content"]
    assert "starting with '@Bobby'" in messages[1]["content"]

    # unaddressed log keeps the generic instruction
    messages = tr.render_messages(NOVA, "t", ["Nova", "Bobby"], [msg("Priya", "hi")])
    assert "speaking directly to you" not in messages[1]["content"]


def test_operator_summons_starts_topic_instead_of_saluting():
    summons = {
        "sender": {"name": "Operator", "kind": "operator"},
        "body": "new topic: pierogi. @Nova, you start.",
        "mentions": [{"name": "Nova"}],
    }
    messages = tr.render_messages(NOVA, "t", ["Nova", "Bobby"], [msg("Bobby", "hi"), summons])
    assert "Do NOT address or @-mention the Operator" in messages[1]["content"]
    assert "starting with '@Operator'" not in messages[1]["content"]


def test_postprocess_strips_meta_prefix():
    raw = "Here's my next message: Reminds me of the sea otters, actually."
    out = tr.postprocess(raw, "Nova", ["Nova"])
    assert out == "Reminds me of the sea otters, actually."


def test_reply_rule_is_in_system_prompt():
    messages = tr.render_messages(NOVA, "t", ["Nova", "Bobby"], [msg("Bobby", "hi")])
    assert "start with their @name" in messages[0]["content"]


def test_postprocess_strips_wrapping_quotes():
    assert tr.postprocess('"hello there"', "Nova", ["Nova"]) == "hello there"


def test_postprocess_caps_sentences():
    raw = "One. Two. Three. Four. Five."
    out = tr.postprocess(raw, "Nova", ["Nova"])
    assert out == "One. Two. Three."


def test_memories_section_absent_when_not_provided():
    messages = tr.render_messages(NOVA, "t", ["Nova", "Bobby"], [msg("Bobby", "hi")])
    assert "Things you remember" not in messages[0]["content"]

    # explicitly empty memories also add nothing
    messages = tr.render_messages(NOVA, "t", ["Nova", "Bobby"], [msg("Bobby", "hi")], memories=[])
    assert "Things you remember" not in messages[0]["content"]


def test_memories_section_appears_when_provided():
    memories = ["talked with Bobby (4 messages) about raccoons", "Bobby addressed me 2 times"]
    messages = tr.render_messages(NOVA, "t", ["Nova", "Bobby"], [msg("Bobby", "hi")], memories=memories)
    system = messages[0]["content"]
    assert "Things you remember about the people here:" in system
    assert "- talked with Bobby (4 messages) about raccoons" in system
    assert "- Bobby addressed me 2 times" in system
