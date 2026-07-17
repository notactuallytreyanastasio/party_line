defmodule PartyLine.Agents.Router do
  @moduledoc """
  Who answers this?

  Pure policy: given the agents online, a message, and whatever the asker asked
  for, decide where it goes. The round-robin cursor is passed in and handed
  back, so fairness is a testable property rather than a hidden counter.

  ## It tries; it doesn't refuse

  "Is there something that's 24B or more?" is a *wish*. On an exchange made of
  strangers' laptops the honest answer when nothing that big is on is "no —
  here's what is", not an error and not a silent substitution. So a request
  that can't be met still gets answered, and the decision says plainly what
  happened:

    * `honored?: false` — you asked for something specific and it isn't here
    * `downshifted?: true` — nobody online is big enough for a question this
      hard, regardless of what you asked

  Both are for the UI to admit out loud. A router that quietly hands a 24B
  question to a 4B is lying; one that refuses is useless. Saying so is neither.

  ## Order

  1. **The ask**, if there is one — `PartyLine.Agents.Target`.
  2. **Complexity** sizes the work — `PartyLine.Agents.Complexity`.
  3. **Round robin** among whoever's left, so one laptop doesn't eat every
     request for having registered first.

  The only real failure is an empty exchange.
  """

  alias PartyLine.Agents.{Card, Complexity, Target}

  @type decision :: %{
          card: Card.t(),
          tier: Complexity.tier(),
          asked: Target.t(),
          honored?: boolean(),
          downshifted?: boolean(),
          cursor: non_neg_integer()
        }

  @doc """
  Route a message.

  `cards` is everyone online. `opts`:

    * `:cursor` — round-robin position; carry it between calls
    * `:target` — an explicit ask (`PartyLine.Agents.Target.t/0`). When absent,
      the message itself is read for one.

  Returns `{:ok, decision}`, or `{:error, :nobody_online}` — the only way to
  fail, because it's the only situation there's nothing honest to do about.
  """
  @spec route([Card.t()], String.t(), keyword()) :: {:ok, decision()} | {:error, :nobody_online}
  def route(cards, message, opts \\ [])

  def route([], _message, _opts), do: {:error, :nobody_online}

  def route(cards, message, opts) do
    cursor = Keyword.get(opts, :cursor, 0)
    # nil means "nobody targeted anything", same as omitting it — get_lazy alone
    # would take an explicit nil at face value and hand it to the filter
    target =
      case Keyword.get(opts, :target) do
        nil -> Target.parse(message, personas(cards))
        explicit -> explicit
      end

    %{tier: tier} = Complexity.assess(message)

    {pool, honored?} = try_target(cards, target)
    {eligible, downshifted?} = size_to(pool, tier)
    {card, next} = deal(eligible, cursor)

    {:ok,
     %{
       card: card,
       tier: tier,
       asked: target,
       honored?: honored?,
       downshifted?: downshifted?,
       cursor: next
     }}
  end

  @doc """
  What to tell the asker when they didn't get what they asked for.

  Returns nil when there's nothing to apologize for — the caller can render it
  unconditionally.
  """
  @spec note(decision()) :: String.t() | nil
  def note(%{honored?: false, asked: asked, card: card}) do
    "nothing #{Target.describe(asked)} is on the exchange right now — asking #{Card.byline(card)}"
  end

  def note(%{downshifted?: true, card: card}) do
    "nobody online is big enough for this one — asking #{Card.byline(card)} anyway"
  end

  def note(_decision), do: nil

  # ── the ask ──────────────────────────────────────────────────────────────

  # An ask nobody can satisfy doesn't empty the pool — it just goes unhonored.
  defp try_target(cards, target) when map_size(target) == 0, do: {cards, true}

  defp try_target(cards, target) do
    case Enum.filter(cards, &Target.satisfies?(&1, target)) do
      [] -> {cards, false}
      matched -> {matched, true}
    end
  end

  # ── sizing ───────────────────────────────────────────────────────────────

  # Everyone who can carry the work; if that's nobody, hand it over anyway and
  # mark it, so the UI can be honest instead of the router being precious.
  defp size_to(pool, tier) do
    case Enum.filter(pool, &Card.can_take?(&1, tier)) do
      [] -> {pool, true}
      eligible -> {eligible, false}
    end
  end

  # ── round robin ──────────────────────────────────────────────────────────

  # Sorted by persona so the ring is stable across calls: the directory is a
  # map underneath, and map order is not an ordering you may rely on. Without
  # this, "round robin" would quietly become "whatever the hash felt like".
  defp deal(eligible, cursor) do
    ring = Enum.sort_by(eligible, & &1.persona)
    index = rem(cursor, length(ring))
    {Enum.at(ring, index), cursor + 1}
  end

  defp personas(cards), do: Enum.map(cards, & &1.persona)
end
