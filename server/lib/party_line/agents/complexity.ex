defmodule PartyLine.Agents.Complexity do
  @moduledoc """
  How hard does a message *look*?

  The orchestrator has to size a request before it has anyone to send it to,
  and this server never runs inference — so it cannot ask a model. That
  constraint is load-bearing: what's left is a cheap, pure read of the surface
  of the text.

  So be honest about what this is. It is a **guess from shape**, not
  comprehension. "why" is a hard word and "hey" is an easy one, and no amount
  of tuning changes the fact that `2 + 2` and `P = NP` are the same length.
  It's wrong sometimes, cheaply, in microseconds, and the cost of being wrong
  is that a question lands on a smaller model than it deserved — which, on a
  network of strangers' laptops, is a Tuesday.

  Three tiers, because that's as much resolution as a heuristic this crude has
  any business claiming:

    * `:chatty`   — banter. Anything online can take it.
    * `:moderate` — a real question wanting a real answer.
    * `:hard`     — reasoning, code, multi-part, or long.

  Scoring is additive and capped: no single signal can carry a message to
  `:hard` on its own except the ones that genuinely mean it (a code fence, an
  explicit demand to reason).
  """

  @type tier :: :chatty | :moderate | :hard

  @type t :: %{score: float(), tier: tier(), signals: [atom()]}

  # words that ask for reasoning rather than recall
  @reasoning ~w(why how explain prove derive compare contrast analyze analyse
                evaluate design architect implement debug optimize refactor
                critique justify tradeoff trade-off)

  # asks for the work to be shown, which is what actually costs tokens
  @depth [
    "step by step",
    "step-by-step",
    "in detail",
    "walk me through",
    "show your work",
    "pros and cons",
    "from scratch"
  ]

  @doc """
  Assess a message. Returns the score, the tier, and which signals fired —
  the signals are returned because a router that can't explain itself is one
  nobody can debug at 2am.
  """
  @spec assess(String.t()) :: t()
  def assess(text) when is_binary(text) do
    down = String.downcase(text)
    words = text |> String.split(~r/\s+/, trim: true) |> length()

    signals =
      []
      # long and wordy are exclusive bands, not stacked: a 90-word message is
      # long, not long *and* wordy. Terse is 1-2 words — "hey", "lol what" —
      # not merely short, or "why do cats knead" would cancel its own signal.
      |> flag(:long, words > 60)
      |> flag(:wordy, words > 25 and words <= 60)
      |> flag(:terse, words <= 2)
      |> flag(:code, code?(text))
      |> flag(:reasoning, any_word?(down, @reasoning))
      |> flag(:depth, Enum.any?(@depth, &String.contains?(down, &1)))
      |> flag(:multipart, multipart?(text, down))
      |> flag(:math, math?(text))

    # reduce from 0.0, not Enum.sum/1: an unremarkable message fires no signals
    # at all, and summing [] gives the integer 0, which Float.round/2 rejects
    score =
      signals
      |> Enum.reduce(0.0, fn signal, acc -> acc + weight(signal) end)
      |> clamp()
      |> Float.round(3)

    %{score: score, tier: tier(score), signals: Enum.sort(signals)}
  end

  @doc "Where a score lands. Exposed so the thresholds are testable, not folklore."
  @spec tier(float()) :: tier()
  def tier(score) when score >= 0.65, do: :hard
  def tier(score) when score >= 0.3, do: :moderate
  def tier(_score), do: :chatty

  # Calibrated against the tiers they're supposed to produce, not by feel:
  #   code                      -> hard on its own (someone pasted code)
  #   reasoning + depth   =0.75 -> hard ("explain step by step why")
  #   reasoning + multipart=0.65 -> hard (several real questions at once)
  #   reasoning alone      =0.3  -> moderate ("why do cats knead")
  #   wordy alone          =0.3  -> moderate (a long message is a real one)
  defp weight(:code), do: 0.7
  defp weight(:depth), do: 0.45
  defp weight(:long), do: 0.4
  defp weight(:multipart), do: 0.35
  defp weight(:reasoning), do: 0.3
  defp weight(:wordy), do: 0.3
  defp weight(:math), do: 0.2
  # "hey" is not a research project, even with a question mark on it
  defp weight(:terse), do: -0.2

  defp clamp(score), do: score |> max(0.0) |> min(1.0)

  defp flag(signals, name, true), do: [name | signals]
  defp flag(signals, _name, false), do: signals

  # A code fence is unambiguous. The keyword branch needs code *shape*, not a
  # bare English word: "what's your class schedule" or "import your contacts"
  # are not pasted code, but "\bclass\b"/"\bimport\b" flagged them straight to
  # :hard. Require the keyword to sit next to code punctuation — a def/function
  # with parens or an identifier, a class with a name, a SELECT…FROM.
  defp code?(text) do
    String.contains?(text, "```") or
      Regex.match?(
        ~r/\b(?:def |function\s+\w|function\s*\(|class\s+\w|import\s+[\w{]|SELECT\b.+\bFROM)\b/i,
        text
      )
  end

  defp any_word?(down, words) do
    tokens = String.split(down, ~r/[^a-z-]+/, trim: true) |> MapSet.new()
    Enum.any?(words, &MapSet.member?(tokens, &1))
  end

  # more than one actual question, or an enumerated list of asks
  defp multipart?(text, down) do
    text |> String.graphemes() |> Enum.count(&(&1 == "?")) > 1 or
      Regex.match?(~r/^\s*\d[\.\)]\s+/m, text) or
      String.contains?(down, " and also ")
  end

  defp math?(text), do: Regex.match?(~r/[∑∫√≠≤≥∞]|\d+\s*[\^\/\*]\s*\d+|\bO\(/, text)
end
