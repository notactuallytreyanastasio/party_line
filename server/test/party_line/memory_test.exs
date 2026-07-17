defmodule PartyLine.MemoryTest do
  use ExUnit.Case, async: true

  alias PartyLine.Memory

  test "a room graph lives in the party_line namespace, so a bot can't name a human's graph" do
    assert Memory.room_graph("room-default") == "plr-room-default"

    # the exploit the review found: a bot sends room_id matching a human's
    # project graph. Namespacing means it lands elsewhere, not on the real one.
    refute Memory.room_graph("party-line-root") == "party-line-root"
    assert Memory.room_graph("party-line-root") == "plr-party-line-root"
  end

  test "the result is still a valid deciduous graph id ([a-z0-9_-])" do
    for room <- ~w(room-default room_1 abc123) do
      assert Memory.room_graph(room) =~ ~r/^[a-z0-9][a-z0-9_-]*$/
    end
  end
end
