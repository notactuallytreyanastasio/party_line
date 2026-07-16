from party_line_harness.inference.engine import extract_channel_final


def test_extracts_harmony_final_channel():
    raw = (
        "<|channel|>analysis<|message|>The user Nova: said something. "
        "I should riff on raccoons.<|end|>"
        "<|start|>assistant<|channel|>final<|message|>honestly the raccoons are winning."
    )
    assert extract_channel_final(raw) == "honestly the raccoons are winning."


def test_extracts_gemma_thought_channel():
    raw = (
        "<|channel>thought\nThinking Process:\n1. Analyze the persona...\n"
        "2. Bobby said: raccoons learned the sensors\n"
        "<channel|>Genius level wildlife. 🤯"
    )
    assert extract_channel_final(raw) == "Genius level wildlife. 🤯"


def test_harmony_analysis_only_forfeits():
    raw = "<|channel|>analysis<|message|>Let me think about what Nova meant..."
    assert extract_channel_final(raw) == ""


def test_gemma_thought_only_forfeits():
    raw = "<|channel>thought\nStill thinking about the perfect reply"
    assert extract_channel_final(raw) == ""


def test_bare_analysis_prefix_forfeits():
    assert extract_channel_final("analysis: the user wants a reply") == ""


def test_plain_text_passes_through():
    assert extract_channel_final("just a normal reply") == "just a normal reply"


def test_residual_control_tokens_stripped():
    raw = "<|channel|>final<|message|>hello there<|end|><|return|>"
    assert extract_channel_final(raw) == "hello there"


def test_roster_names_in_thought_do_not_truncate_final():
    raw = (
        "<|channel>thought\nNova: is the last speaker\nBobby: asked me\n"
        "<channel|>@Bobby the moon tonight, no equipment needed."
    )
    assert extract_channel_final(raw) == "@Bobby the moon tonight, no equipment needed."
