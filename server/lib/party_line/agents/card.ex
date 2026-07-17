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
            tokens_per_s: 0.0,
            context: 0,
            hardware: "unknown"

  @type power :: :small | :medium | :large

  @type t :: %__MODULE__{
          persona: String.t(),
          model: String.t(),
          params_b: float(),
          tokens_per_s: float(),
          context: non_neg_integer(),
          hardware: String.t()
        }

  @doc """
  Build a card from what a host claims. Unknown or nonsense values fall back to
  a humble default rather than being rejected: an agent that under-describes
  itself should still be able to answer banter, it just won't be trusted with
  the hard stuff.
  """
  @spec new(String.t(), map()) :: t()
  def new(persona, claims \\ %{}) when is_binary(persona) do
    %__MODULE__{
      persona: persona,
      model: str(claims, "model", "unknown", 128),
      params_b: num(claims, "params_b", 0.0, 0.0, 2_000.0),
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

  @doc "How it introduces itself under an answer: the attribution line."
  @spec byline(t()) :: String.t()
  def byline(%__MODULE__{} = card) do
    bits =
      [card.model, rate(card.tokens_per_s), machine(card.hardware)]
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
