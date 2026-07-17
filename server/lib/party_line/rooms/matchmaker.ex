defmodule PartyLine.Rooms.Matchmaker do
  @moduledoc """
  Where you land when you stumble.

  Not `Enum.random/1`. A stumble that drops you into an empty room where
  nobody is talking is indistinguishable from a broken site, so a line has to
  *earn* its odds: bots actually present, and recently saying something. Among
  the lines that qualify it genuinely is random — the surprise is the whole
  point — but the dice are loaded toward the ones worth landing in.

  This is pure policy over a plain list of room summaries. The randomness is
  injected (`:roll`), so "loaded dice" is a testable claim rather than a
  hopeful comment.

  A candidate is a map:

      %{
        id: "room-default",
        bots: 3,          # bots on the line right now
        humans: 1,        # humans who've announced themselves
        silent_beats: 0,  # consecutive beats nobody spoke; the liveness signal
        said_anything?: true
      }
  """

  @type candidate :: %{
          :id => String.t(),
          :bots => non_neg_integer(),
          :humans => non_neg_integer(),
          :silent_beats => non_neg_integer(),
          :said_anything? => boolean(),
          optional(any()) => any()
        }

  @doc """
  Pick a line to stumble into, or nil when none is worth it.

  Options:

    * `:exclude` — id (or ids) you're already on. You cannot stumble in place.
    * `:roll` — a 0-arity fn returning a float in [0,1). Injected for tests.
  """
  @spec pick([candidate()], keyword()) :: candidate() | nil
  def pick(rooms, opts \\ []) do
    exclude = opts |> Keyword.get(:exclude, []) |> List.wrap() |> MapSet.new()
    roll = Keyword.get(opts, :roll, fn -> :rand.uniform() end)

    weighted =
      rooms
      |> Enum.reject(&MapSet.member?(exclude, &1.id))
      |> Enum.map(&{&1, weight(&1)})
      |> Enum.filter(fn {_room, w} -> w > 0 end)

    draw(weighted, roll)
  end

  @doc """
  How much this line deserves a stranger, from 0 (never) up.

  Zero means "don't send anyone here": an empty room is a dead end, and so is
  one that has never said a word. Otherwise the weight decays as the line goes
  quiet, and leans slightly toward rooms where other people are already
  listening — a stumble is better with an audience.
  """
  @spec weight(candidate()) :: float()
  def weight(%{bots: 0}), do: 0.0
  def weight(%{said_anything?: false}), do: 0.0

  def weight(room) do
    # a second bot is what makes a line a conversation rather than a monologue,
    # so the jump from 1 to 2 matters more than 4 to 5
    voices = :math.sqrt(room.bots)

    # the room's own dead-air counter, straight from the director
    liveness = 1.0 / (1.0 + room.silent_beats)

    company = 1.0 + min(room.humans, 3) * 0.15

    Float.round(voices * liveness * company, 6)
  end

  # Cumulative weighted draw. `roll` lands somewhere in the total; whichever
  # room's slice contains it wins, so a room twice as lively is twice as likely.
  defp draw([], _roll), do: nil

  defp draw(weighted, roll) do
    total = weighted |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    target = roll.() * total

    weighted
    |> Enum.reduce_while(0.0, fn {room, w}, acc ->
      if acc + w > target, do: {:halt, room}, else: {:cont, acc + w}
    end)
    |> case do
      # a roll of exactly 1.0 (or float drift) can walk off the end
      acc when is_float(acc) -> weighted |> List.last() |> elem(0)
      room -> room
    end
  end
end
