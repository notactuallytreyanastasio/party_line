defmodule PartyLine.Boards.PolicyTest do
  use ExUnit.Case, async: true

  alias PartyLine.Boards.Policy
  alias PartyLine.Boards.Post

  defp post(id, board, author),
    do: %Post{
      id: id,
      board: board,
      topic: "t",
      author: author,
      body: "b",
      created_at: ~U[2026-06-01 00:00:00Z]
    }

  describe "posting decisions" do
    test "stalest board wins — empty boards first, then oldest" do
      boards = ~w(a b c)
      assert Policy.stalest_board(boards, %{"a" => 1000, "c" => 5000}) == "b"
      assert Policy.stalest_board(boards, %{"a" => 1000, "b" => 9000, "c" => 5000}) == "a"
    end

    test "pick_board: empty first, then stalest, ties by name, nil when boardless" do
      boards = ~w(a b c)
      assert Policy.pick_board(boards, %{"a" => 1000, "c" => 5000}) == "b"
      assert Policy.pick_board(boards, %{"a" => 1000, "b" => 9000, "c" => 5000}) == "a"
      assert Policy.pick_board(boards, %{"a" => 1000}) == "b"
      assert Policy.pick_board([], %{}) == nil
    end

    test "persona pick: fewest posts on this board, then least-recently assigned" do
      assert Policy.pick_persona(~w(Ada Bo Cy), "x", %{}, %{{"x", "Ada"} => 3, {"x", "Bo"} => 1}) ==
               "Cy"

      assert Policy.pick_persona(~w(Ada Bo), "x", %{"Ada" => 100, "Bo" => 5}, %{}) == "Bo"
      assert Policy.pick_persona([], "confessions", %{}, %{}) == nil
    end

    test "persona pick works with multi-word lowercase handles" do
      online = ["erowid smoothie", "horse dentist", "gas station sushi"]
      counts = %{{"confessions", "erowid smoothie"} => 2, {"confessions", "horse dentist"} => 1}
      assert Policy.pick_persona(online, "confessions", %{}, counts) == "gas station sushi"
    end

    test "fresh_topic rejects repeats and exhausted seeds" do
      recent = MapSet.new(["seen it"])
      assert Policy.fresh_topic("new one", recent) == "new one"
      assert Policy.fresh_topic("seen it", recent) == nil
      assert Policy.fresh_topic(nil, recent) == nil
    end
  end

  describe "commenting decisions" do
    test "picks an under-commented post, from a non-author who hasn't weighed in" do
      posts = [post("p1", "sagas", "ada"), post("p2", "sagas", "bo")]
      online = ["ada", "bo", "cy"]

      # nobody has commented yet — the emptiest post (tie → p1), non-author, least recently asked
      assert {%{id: "p1"}, persona} = Policy.pick_comment(posts, online, %{}, %{})
      assert persona in ["bo", "cy"]
      refute persona == "ada"
    end

    test "never comments on your own post or twice on the same post" do
      posts = [post("p1", "sagas", "ada")]
      # only ada online, but it's ada's post → nobody eligible
      assert Policy.pick_comment(posts, ["ada"], %{}, %{}) == nil
      # bo already commented on p1 → nobody left
      assert Policy.pick_comment(posts, ["bo"], %{"p1" => MapSet.new(["bo"])}, %{}) == nil
    end

    test "spreads to the emptiest post" do
      posts = [post("p1", "sagas", "ada"), post("p2", "sagas", "ada")]
      # p1 already has two comments; p2 has none → p2 next
      commenters = %{"p1" => MapSet.new(["x", "y"])}
      assert {%{id: "p2"}, "bo"} = Policy.pick_comment(posts, ["bo"], commenters, %{})
    end
  end

  describe "voting decisions" do
    test "picks a non-author who hasn't voted; direction follows the roll" do
      posts = [post("p1", "sagas", "ada")]
      assert {%{id: "p1"}, "bo", :up} = Policy.pick_vote(posts, ["bo"], %{}, 0.1)
      assert {%{id: "p1"}, "bo", :down} = Policy.pick_vote(posts, ["bo"], %{}, 0.99)
      # already voted → nothing
      assert Policy.pick_vote(posts, ["bo"], %{"p1" => MapSet.new(["bo"])}, 0.1) == nil
      # own post → nothing
      assert Policy.pick_vote(posts, ["ada"], %{}, 0.1) == nil
    end
  end

  describe "pacing + the gate" do
    test "drip delay is exponential around the mean, integer ms, guarded" do
      assert Policy.drip_delay(1000, 1.0) == 0
      assert Policy.drip_delay(1000, 0.5) == round(1000 * :math.log(2))
      assert Policy.drip_delay(1000, 0.01) > 1000
      assert is_integer(Policy.drip_delay(1234, 0.37))
      assert_raise FunctionClauseError, fn -> Policy.drip_delay(1000, 0) end
      assert_raise FunctionClauseError, fn -> Policy.drip_delay(1000, 1.5) end
    end

    test "light gate drops empty, short, refusals, nil, and near-dupes" do
      refute Policy.acceptable?("", [])
      refute Policy.acceptable?(nil, [])
      refute Policy.acceptable?("too short", [])
      refute Policy.acceptable?("I can't help with that request", [])
      refute Policy.acceptable?("I'M SORRY but the raccoons said no", [])
      assert Policy.acceptable?("the molars knew all along, honestly", [])
      # mid-string marker is not a refusal
      assert Policy.acceptable?("they told me i can't post this, so here it is anyway", [])
      # near-duplicate: same normalized 60-char signature
      refute Policy.acceptable?("the molars knew all along", ["The Molars Knew, all along!!"])
    end
  end
end
