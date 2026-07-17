defmodule PartyLine.Agents.Card do
  @moduledoc """
  What a leased agent says it can do.

  An agent is a persona *on a particular machine*: "Horse Dentist, running
  gemma-4-e4b at 42 tok/s on someone's MacBook". The persona is the goofy part;
  the machine is the capability part; you don't get to pick them apart, and
  that pairing is the whole charm of the network. A big model with a stupid
  personality and a tiny model with a stupid personality are different products.

  Everything here is **claimed by the host**, not measured by us. A stranger's
  daemon reports its own tok/s. Treat these as advertisements: good enough to
  route on, never good enough to trust — which is why `new/2` clamps rather
  than believes, and why nothing here is a promise to a user.
  """

  @enforce_keys [:persona]
  defstruct persona: nil,
            model: "unknown",
            params_b: 0.0,
            quant: nil,
            quant_bits: 0,
            tokens_per_s: 0.0,
            context: 0,
            hardware: "unknown"

  @type power :: :small | :medium | :large

  @type t :: %__MODULE__{
          persona: String.t(),
          model: String.t(),
          params_b: float(),
          quant: String.t() | nil,
          quant_bits: non_neg_integer(),
          tokens_per_s: float(),
          context: non_neg_integer(),
          hardware: String.t()
        }

  # Bits per weight, lowest first. Ordered because a name can mention more than
  # one ("gpt-oss-20b-MXFP4-Q8" is 4-bit weights with 8-bit something-else) and
  # the honest read of a mixed quant is its weakest link, not its flattering half.
  @quants [
    {2, ~r/\b(?:q2|2[-_]?bit|int2)\b/},
    {3, ~r/\b(?:q3|3[-_]?bit|int3)\b/},
    {4, ~r/\b(?:q4|4[-_]?bit|int4|mxfp4|nf4|fp4)\b/},
    {5, ~r/\b(?:q5|5[-_]?bit)\b/},
    {6, ~r/\b(?:q6|6[-_]?bit|int6)\b/},
    {8, ~r/\b(?:q8|8[-_]?bit|int8|fp8)\b/},
    {16, ~r/\b(?:fp16|bf16|f16|float16|half)\b/},
    {32, ~r/\b(?:fp32|f32|float32|full[-_]?precision)\b/}
  ]

  @doc """
  Build a card from what a host claims. Unknown or nonsense values fall back to
  a humble default rather than being rejected: an agent that under-describes
  itself should still be able to answer banter, it just won't be trusted with
  the hard stuff.
  """
  @spec new(String.t(), map()) :: t()
  def new(persona, claims \\ %{}) when is_binary(persona) do
    model = str(claims, "model", "unknown", 128)
    quant = str(claims, "quant", nil, 32)

    %__MODULE__{
      persona: persona,
      model: model,
      # Same reasoning as quant: a host that named "...-8B-Instruct-4bit" has
      # already told us how big it is. Read it back only when it didn't say —
      # an explicit claim always wins over us squinting at a string.
      params_b: num(claims, "params_b", params_from(model), 0.0, 2_000.0),
      quant: quant,
      # A host that named its model already told us its quant, whether or not
      # it meant to — reading it back off the id is not a guess, it's the
      # host's own claim spelled a different way.
      quant_bits: quant_bits(quant || model),
      tokens_per_s: num(claims, "tokens_per_s", 0.0, 0.0, 100_000.0),
      context: claims |> num("context", 0, 0, 10_000_000) |> trunc(),
      hardware: str(claims, "hardware", "unknown", 64)
    }
  end

  @doc """
  How much model this is, coarsely.

  Three buckets because the routing tiers are three, and because parameter
  count is already a lie told in public — the boundary between a 7B and an 8B
  is not a thing a router should pretend to resolve.

  A card that never said how big it is reads as `:small`: claim nothing, get
  the easy work.
  """
  @spec power(t()) :: power()
  def power(%__MODULE__{params_b: b}) when b >= 14.0, do: :large
  def power(%__MODULE__{params_b: b}) when b >= 5.0, do: :medium
  def power(%__MODULE__{}), do: :small

  @doc """
  Can this agent take work of the given complexity?

  Deliberately *not* "is it the same tier" — a big model may answer banter, and
  frequently should, because the alternative is idling a 70B while someone asks
  it to say hi.
  """
  @spec can_take?(t(), PartyLine.Agents.Complexity.tier()) :: boolean()
  def can_take?(card, :chatty), do: power(card) in [:small, :medium, :large]
  def can_take?(card, :moderate), do: power(card) in [:medium, :large]
  def can_take?(card, :hard), do: power(card) == :large

  @doc """
  Billions of parameters named in `text`, or 0.0 when it says nothing.

  Deliberately narrow: `-4bit` and `-8bit` are quantization, not size, and a
  bare version number ("gemma-4") is not a 4B claim. When in doubt it says
  nothing, which reads as `:small` — silence must lose the hard work, not win it.
  """
  @spec params_from(String.t()) :: float()
  def params_from(text) do
    # No leading \b on purpose: gemma names its size *inside* a token
    # ("gemma-4-e4b" = effective 4B), and a boundary there would miss it. The
    # trailing b\b still rules out "-4bit"/"-8bit", which are quantization.
    case Regex.run(~r/(\d+(?:\.\d+)?)\s*b\b/, String.downcase(text)) do
      [_, n] ->
        {size, _} = Float.parse(n)
        if size >= 0.1 and size <= 2_000.0, do: size, else: 0.0

      _ ->
        0.0
    end
  end

  @doc """
  Bits per weight named anywhere in `text`, or 0 when it says nothing.

  Higher is better: fewer bits means more of the model was thrown away to make
  it fit on a laptop. That ordering is what makes "8bit or better" a question
  someone can actually ask.
  """
  @spec quant_bits(String.t() | nil) :: non_neg_integer()
  def quant_bits(nil), do: 0

  def quant_bits(text) do
    down = String.downcase(text)

    case Enum.find(@quants, fn {_bits, re} -> Regex.match?(re, down) end) do
      {bits, _re} -> bits
      nil -> 0
    end
  end

  @doc "How it introduces itself under an answer: the attribution line."
  @spec byline(t()) :: String.t()
  def byline(%__MODULE__{} = card) do
    bits =
      [card.model, card.quant, rate(card.tokens_per_s), machine(card.hardware)]
      |> Enum.reject(&is_nil/1)

    "#{card.persona} · " <> Enum.join(bits, " · ")
  end

  # +0.0 vs -0.0: match on the meaning ("never claimed a rate"), not the bits
  defp rate(t) when t == 0.0, do: nil
  defp rate(t), do: "#{round(t)} tok/s"

  defp machine("unknown"), do: nil
  defp machine(h), do: h

  defp str(claims, key, default, max) do
    case get(claims, key) do
      s when is_binary(s) and s != "" -> String.slice(s, 0, max)
      _ -> default
    end
  end

  defp num(claims, key, default, lo, hi) do
    case get(claims, key) do
      n when is_number(n) -> n |> max(lo) |> min(hi) |> :erlang.float()
      _ -> default
    end
  end

  defp get(claims, key), do: Map.get(claims, key) || Map.get(claims, String.to_atom(key))
end
