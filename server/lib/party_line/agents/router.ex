defmodule PartyLine.Agents.Router do
  @moduledoc """
  Who answers this?

  Pure policy: given the agents currently online, a message, and what the user
  asked for, decide where it goes. The cursor for round-robin is passed in and
  handed back, so fairness is a testable property and not a hidden counter.

  ## The order of operations

  1. **Targeting wins.** If a user asked for a specific persona, model, or
     class of machine, they get it or they get told nobody like that is on.
     A router that quietly ignores what you asked for is worse than one that
     says no.
  2. **Complexity sizes the work** — see `PartyLine.Agents.Complexity`.
  3. **Round robin among the eligible**, so leasing is fair: the same laptop
     doesn't eat every request just because it registered first.

  ## When nobody is big enough

  It downshifts and says so, rather than refusing. This network is strangers'
  laptops — the honest failure is "a 4B model took your hard question", not a
  spinner waiting for a 70B that is never coming. The caller gets
  `downshifted?: true` so the UI can admit it.
  """

  alias PartyLine.Agents.{Card, Complexity}

  @type target :: %{
          optional(:persona) => String.t(),
          optional(:model) => String.t(),
          optional(:power) => Card.power()
        }

  @type decision :: %{
          card: Card.t(),
          tier: Complexity.tier(),
          downshifted?: boolean(),
          cursor: non_neg_integer()
        }

  @doc """
  Route a message.

  `cards` is everyone online. `opts`:

    * `:cursor` — round-robin position (carry it between calls)
    * `:target` — `%{persona:}` / `%{model:}` / `%{power:}`

  Returns `{:ok, decision}` or `{:error, :nobody_online | {:no_match, target}}`.
  """
  @spec route([Card.t()], String.t(), keyword()) :: {:ok, decision()} | {:error, term()}
  def route(cards, message, opts \\ [])

  def route([], _message, _opts), do: {:error, :nobody_online}

  def route(cards, message, opts) do
    cursor = Keyword.get(opts, :cursor, 0)
    target = Keyword.get(opts, :target)
    %{tier: tier} = Complexity.assess(message)

    case targeted(cards, target) do
      {:error, reason} ->
        {:error, reason}

      pool ->
        {eligible, downshifted?} = size_to(pool, tier)
        {card, next} = deal(eligible, cursor)

        {:ok, %{card: card, tier: tier, downshifted?: downshifted?, cursor: next}}
    end
  end

  # ── targeting ────────────────────────────────────────────────────────────

  defp targeted(cards, nil), do: cards

  defp targeted(cards, target) do
    case Enum.filter(cards, &matches?(&1, target)) do
      [] -> {:error, {:no_match, target}}
      pool -> pool
    end
  end

  defp matches?(card, target) do
    Enum.all?(target, fn
      {:persona, name} -> String.downcase(card.persona) == String.downcase(name)
      {:model, model} -> card.model =~ model
      {:power, power} -> Card.power(card) == power
      {_other, _} -> false
    end)
  end

  # ── sizing ───────────────────────────────────────────────────────────────

  # Take everyone who can carry the work. If nobody can, don't fail — hand it
  # to whoever is online and mark it, so the UI can be honest instead of the
  # router being precious.
  defp size_to(pool, tier) do
    case Enum.filter(pool, &Card.can_take?(&1, tier)) do
      [] -> {pool, true}
      eligible -> {eligible, false}
    end
  end

  # ── round robin ──────────────────────────────────────────────────────────

  # Sorted by persona so the ring is stable across calls: the directory is a
  # map underneath, and map order is not an ordering you may rely on. Without
  # this, "round robin" would silently become "whatever the hash felt like".
  defp deal(eligible, cursor) do
    ring = Enum.sort_by(eligible, & &1.persona)
    index = rem(cursor, length(ring))
    {Enum.at(ring, index), cursor + 1}
  end
end
