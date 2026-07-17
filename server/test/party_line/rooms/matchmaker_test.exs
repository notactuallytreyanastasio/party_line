defmodule PartyLine.Rooms.MatchmakerTest do
  @moduledoc """
  The stumble is "matchmade, not true random" — which is only a real claim if
  the weighting is pinned. The roll is injected, so these assert exactly where
  a given roll lands rather than sampling and hoping.
  """
  use ExUnit.Case, async: true

  alias PartyLine.Rooms.Matchmaker

  defp room(id, opts \\ []) do
    %{
      id: id,
      bots: Keyword.get(opts, :bots, 2),
      humans: Keyword.get(opts, :humans, 0),
      silent_beats: Keyword.get(opts, :silent_beats, 0),
      said_anything?: Keyword.get(opts, :said?, true)
    }
  end

  describe "who deserves a stranger" do
    test "an empty line never gets one — that's a dead end, not a stumble" do
      assert Matchmaker.weight(room("a", bots: 0)) == 0.0
    end

    test "a line that has never said a word never gets one either" do
      assert Matchmaker.weight(room("a", bots: 3, said?: false)) == 0.0
    end

    test "weight decays as the line goes quiet" do
      loud = Matchmaker.weight(room("a", silent_beats: 0))
      quiet = Matchmaker.weight(room("a", silent_beats: 3))
      silent = Matchmaker.weight(room("a", silent_beats: 20))

      assert loud > quiet
      assert quiet > silent
      assert silent > 0, "a quiet room is still a room; only an empty one is out"
    end

    test "the jump from a monologue to a conversation matters most" do
      # sqrt: 1→2 buys more than 4→5, because that's the jump that makes it
      # a conversation at all
      solo_to_duo = Matchmaker.weight(room("a", bots: 2)) - Matchmaker.weight(room("a", bots: 1))
      four_to_five = Matchmaker.weight(room("a", bots: 5)) - Matchmaker.weight(room("a", bots: 4))

      assert solo_to_duo > four_to_five
    end

    test "an audience helps, but only a little, and it saturates" do
      alone = Matchmaker.weight(room("a", humans: 0))
      couple = Matchmaker.weight(room("a", humans: 2))
      mob = Matchmaker.weight(room("a", humans: 50))

      assert couple > alone
      assert mob == Matchmaker.weight(room("a", humans: 3)), "caps at 3 — a crowd isn't better"
      assert mob < alone * 1.5, "company is a nudge, not the whole score"
    end
  end

  describe "picking" do
    test "you cannot stumble in place" do
      rooms = [room("here"), room("there")]

      assert %{id: "there"} = Matchmaker.pick(rooms, exclude: "here", roll: fn -> 0.0 end)
      assert %{id: "there"} = Matchmaker.pick(rooms, exclude: ["here"], roll: fn -> 0.99 end)
    end

    test "nowhere to go returns nil rather than a dead room" do
      assert Matchmaker.pick([], roll: fn -> 0.5 end) == nil
      assert Matchmaker.pick([room("a", bots: 0)], roll: fn -> 0.5 end) == nil

      # the only live line is the one you're on
      assert Matchmaker.pick([room("here")], exclude: "here", roll: fn -> 0.5 end) == nil
    end

    test "the dice are loaded: a livelier line owns a bigger slice of the roll" do
      # lively weight = sqrt(4)*1        = 2.0
      # dozing weight = sqrt(4)*(1/(1+3)) = 0.5   → total 2.5
      rooms = [room("lively", bots: 4), room("dozing", bots: 4, silent_beats: 3)]

      # the first 80% of the roll belongs to the lively room
      assert %{id: "lively"} = Matchmaker.pick(rooms, roll: fn -> 0.0 end)
      assert %{id: "lively"} = Matchmaker.pick(rooms, roll: fn -> 0.79 end)
      # and the tail to the dozing one — it's still reachable, just rarer
      assert %{id: "dozing"} = Matchmaker.pick(rooms, roll: fn -> 0.81 end)
    end

    test "a roll of exactly 1.0 still lands somewhere" do
      rooms = [room("a"), room("b")]
      assert %{id: _} = Matchmaker.pick(rooms, roll: fn -> 1.0 end)
    end

    test "every live line is reachable — it's a stumble, not a ranking" do
      rooms = [room("a", bots: 5), room("b", bots: 1, silent_beats: 8), room("c", bots: 2)]

      landed =
        for r <- 0..99 do
          Matchmaker.pick(rooms, roll: fn -> r / 100 end).id
        end
        |> Enum.uniq()
        |> Enum.sort()

      assert landed == ["a", "b", "c"]
    end

    test "the default roll is real randomness, and it stays inside the candidates" do
      rooms = [room("a"), room("b")]
      landed = for _ <- 1..50, do: Matchmaker.pick(rooms).id
      assert Enum.all?(landed, &(&1 in ["a", "b"]))
    end
  end
end
