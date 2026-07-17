defmodule PartyLine.Agents.TargetTest do
  @moduledoc """
  Reading an ask out of a message is a regex over the surface, for the same
  reason complexity is: no inference server-side. So the bar is "catches the
  obvious phrasings, invents nothing" — a missed ask must cost a default
  route, never an error, and never a constraint nobody asked for.
  """
  use ExUnit.Case, async: true

  alias PartyLine.Agents.{Card, Target}

  describe "size floors — the ask you actually asked for" do
    test "the phrasings people type" do
      assert Target.parse("is there something that's 24B or more?") == %{min_params_b: 24.0}
      assert Target.parse("anything 24b+") == %{min_params_b: 24.0}
      assert Target.parse("at least 24B please") == %{min_params_b: 24.0}
      assert Target.parse("bigger than 8b") == %{min_params_b: 8.0}
      assert Target.parse("got a 70B model?") == %{min_params_b: 70.0}
      assert Target.parse("something 7.5b or bigger") == %{min_params_b: 7.5}
    end
  end

  describe "inventing nothing" do
    test "an ordinary message asks for nothing at all" do
      assert Target.parse("hey what's up") == %{}
      assert Target.parse("why do cats knead") == %{}
    end

    test "a number that isn't a model size is not a constraint" do
      assert Target.parse("i have 24 browser tabs open") == %{}
      assert Target.parse("what happened in 1998") == %{}
    end

    test "a persona is only read when we actually know the name" do
      # unknown names must not become constraints, or every proper noun would
      assert Target.parse("ask horse dentist about it") == %{}

      assert Target.parse("ask horse dentist about it", ["Horse Dentist"]) ==
               %{persona: "Horse Dentist"}
    end
  end

  describe "quantization — the quality ask" do
    test "the phrasings people type" do
      assert Target.parse("8bit or better") == %{min_quant_bits: 8}
      assert Target.parse("8-bit or higher") == %{min_quant_bits: 8}
      assert Target.parse("at least 8bit") == %{min_quant_bits: 8}
      assert Target.parse("anything fp16?") == %{min_quant_bits: 16}
      assert Target.parse("give me something unquantized") == %{min_quant_bits: 16}
      assert Target.parse("full-precision please") == %{min_quant_bits: 16}
    end

    test "it composes with a size ask — they're different questions" do
      assert Target.parse("is there something thats 24B or more, 8bit or better?") ==
               %{min_params_b: 24.0, min_quant_bits: 8}
    end

    test "bits that aren't a quantization ask invent nothing" do
      assert Target.parse("i have 8 bits of ram") == %{}
      assert Target.parse("the 8 bit era was great") == %{}
    end

    test "an unclaimed quant fails every floor: silence loses" do
      shy = Card.new("shy", %{"model" => "mystery-model"})
      assert shy.quant_bits == 0
      refute Target.satisfies?(shy, %{min_quant_bits: 4})
    end

    test "a floor is a floor" do
      card = Card.new("a", %{"model" => "m-8bit"})
      assert Target.satisfies?(card, %{min_quant_bits: 8})
      assert Target.satisfies?(card, %{min_quant_bits: 4})
      refute Target.satisfies?(card, %{min_quant_bits: 16})
    end

    test "describe reads back the way a person would say it" do
      assert Target.describe(%{min_quant_bits: 8}) == "8bit or better"
      assert Target.describe(%{min_quant_bits: 16}) == "fp16 or better"
    end
  end

  describe "speed and model" do
    test "a speed floor" do
      assert Target.parse("at least 30 tok/s") == %{min_tokens_per_s: 30.0}
      assert Target.parse("faster than 20 tokens/s") == %{min_tokens_per_s: 20.0}
    end

    test "a model family" do
      assert Target.parse("use gpt-oss for this") == %{model: "gpt-oss"}
      assert Target.parse("on gemma please") == %{model: "gemma"}
    end
  end

  describe "satisfies?" do
    test "a floor is a floor: at it passes, under it doesn't" do
      card = Card.new("a", %{"params_b" => 24})

      assert Target.satisfies?(card, %{min_params_b: 24.0})
      assert Target.satisfies?(card, %{min_params_b: 8.0})
      refute Target.satisfies?(card, %{min_params_b: 70.0})
    end

    test "every stated constraint has to hold" do
      card = Card.new("a", %{"params_b" => 24, "tokens_per_s" => 10, "model" => "gpt-oss-24b"})

      assert Target.satisfies?(card, %{min_params_b: 24.0, model: "gpt-oss"})
      refute Target.satisfies?(card, %{min_params_b: 24.0, min_tokens_per_s: 50.0})
    end

    test "an empty ask is satisfied by anyone" do
      assert Target.satisfies?(Card.new("whoever"), %{})
    end
  end

  describe "describe" do
    test "reads back the way a person would say it" do
      assert Target.describe(%{min_params_b: 24.0}) == "24B or bigger"
      assert Target.describe(%{min_tokens_per_s: 30.0}) == "30 tok/s or faster"
      assert Target.describe(%{persona: "Horse Dentist"}) == "Horse Dentist"
      assert Target.describe(%{}) == "anything"
    end
  end

  describe "malformed numbers never crash the correlator" do
    test "a 300-digit number is not a constraint and does not raise" do
      # This runs inside the singleton Asks GenServer's handle_call. String.to_float
      # raised ArgumentError on an out-of-range literal, which would take down every
      # concurrent pending ask — a remote DoS from one chat message.
      huge = String.duplicate("9", 320)
      assert Target.parse("is there something thats #{huge}b or more?") == %{}
      assert Target.parse("at least #{huge} tok/s") == %{}
    end

    test "a plausible but large number is dropped rather than raising" do
      assert Target.parse("anything 999999999999b or more?") == %{}
    end
  end
end
