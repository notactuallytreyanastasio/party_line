defmodule PartyLine.Agents.ComplexityTest do
  @moduledoc """
  The heuristic is crude on purpose (the server can't run inference to ask a
  model how hard something is). These pin the thresholds and the signals so
  "crude" stays *deliberate* rather than drifting into arbitrary.
  """
  use ExUnit.Case, async: true

  alias PartyLine.Agents.Complexity

  defp tier(text), do: Complexity.assess(text).tier

  describe "banter" do
    test "greetings and one-liners are chatty" do
      assert tier("hey") == :chatty
      assert tier("lol what") == :chatty
      assert tier("what's up") == :chatty
    end

    test "a plain question is not automatically hard" do
      assert tier("what time is it in tokyo") == :chatty
    end
  end

  describe "real questions" do
    test "asking for reasoning lifts it off banter" do
      assert tier("why do cats knead") == :moderate
      assert tier("explain the offside rule") == :moderate
    end

    test "length alone is enough to stop being banter" do
      assert tier(String.duplicate("word ", 30)) == :moderate
    end
  end

  describe "hard" do
    test "pasted code means it, on its own" do
      assert tier("```\ndef foo, do: :bar\n```") == :hard
    end

    test "reasoning plus a demand to show the work" do
      assert tier("explain step by step why this is faster") == :hard
    end

    test "long and reasoning together" do
      assert tier("why " <> String.duplicate("consider this carefully ", 30)) == :hard
    end

    test "several questions at once" do
      assert tier("why is the sky blue? and how does rayleigh scattering work? explain") == :hard
    end
  end

  describe "the signals are legible" do
    test "it reports what fired, so a routing decision can be explained" do
      assert %{signals: signals} = Complexity.assess("```\ncode\n```")
      assert :code in signals

      assert %{signals: s2} = Complexity.assess("hey")
      assert :terse in s2
    end

    test "terse pulls down: a short reasoning word isn't a research project" do
      assert Complexity.assess("why").score < Complexity.assess("why do cats knead").score
    end

    test "score is capped at 1.0 no matter how much piles on" do
      kitchen_sink = """
      ```elixir
      def f, do: 1
      ```
      why and how does this work? explain step by step, in detail, and also
      1. compare it
      2. prove the O(n) bound with ∑
      #{String.duplicate("more words ", 40)}
      """

      assert Complexity.assess(kitchen_sink).score == 1.0
    end
  end

  describe "thresholds" do
    test "tier/1 boundaries are exact, not vibes" do
      assert Complexity.tier(0.0) == :chatty
      assert Complexity.tier(0.299) == :chatty
      assert Complexity.tier(0.3) == :moderate
      assert Complexity.tier(0.649) == :moderate
      assert Complexity.tier(0.65) == :hard
      assert Complexity.tier(1.0) == :hard
    end
  end

  test "an empty message doesn't crash the router that depends on this" do
    assert %{tier: :chatty} = Complexity.assess("")
  end
end
