defmodule PartyLine.Boards.SchedulerTest do
  use ExUnit.Case, async: true

  alias PartyLine.Boards
  alias PartyLine.Boards.{Scheduler, SchedulerPolicy}

  describe "policy (pure)" do
    test "stalest board wins — empty boards first, then oldest" do
      boards = ~w(a b c)
      # b never posted (nil), a is old, c is new
      fresh = %{"a" => 1000, "c" => 5000}
      assert SchedulerPolicy.stalest_board(boards, fresh) == "b"
      # once b has a fresh post, the oldest (a) is next
      assert SchedulerPolicy.stalest_board(boards, %{"a" => 1000, "b" => 9000, "c" => 5000}) ==
               "a"
    end

    test "persona pick: fewest posts on this board, then least-recently assigned" do
      online = ~w(Ada Bo Cy)
      counts = %{{"x", "Ada"} => 3, {"x", "Bo"} => 1}
      assert SchedulerPolicy.pick_persona(online, "x", %{}, counts) == "Cy"
      # tie at 0 posts → least recently assigned
      assert SchedulerPolicy.pick_persona(~w(Ada Bo), "x", %{"Ada" => 100, "Bo" => 5}, %{}) ==
               "Bo"
    end

    test "fresh_topic rejects repeats" do
      recent = MapSet.new(["seen it"])
      assert SchedulerPolicy.fresh_topic("new one", recent) == "new one"
      assert SchedulerPolicy.fresh_topic("seen it", recent) == nil
    end

    test "drip delay is exponential around the mean" do
      # u→1 gives ~0, u→0 gives large; midpoint is a fraction of the mean
      assert SchedulerPolicy.drip_delay(1000, 1.0) == 0
      assert SchedulerPolicy.drip_delay(1000, 0.5) == round(1000 * :math.log(2))
      assert SchedulerPolicy.drip_delay(1000, 0.01) > 1000
    end

    test "light gate drops empty, refusals, and near-dupes" do
      refute SchedulerPolicy.acceptable?("", [])
      refute SchedulerPolicy.acceptable?("too short", [])
      refute SchedulerPolicy.acceptable?("I can't help with that request", [])
      assert SchedulerPolicy.acceptable?("the molars knew all along, honestly", [])
      # near-duplicate: same normalized signature
      existing = ["The Molars Knew, all along!!"]
      refute SchedulerPolicy.acceptable?("the molars knew all along", existing)
    end
  end

  describe "the loop (shell with fakes)" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "sched-boards-#{System.unique_integer([:positive])}.dets")

      {:ok, boards} =
        Boards.start_link(name: nil, path: path, table: :"b#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(path) end)
      %{boards: boards}
    end

    test "assign → deliver → drip populates the boards, honoring the gate", %{boards: boards} do
      test = self()
      topics = ["what is the deal with airline food", "why do cats knock things off tables"]
      {:ok, topic_agent} = Agent.start_link(fn -> topics end)

      {:ok, sched} =
        Scheduler.start_link(
          name: nil,
          manual: true,
          enabled: true,
          boards: boards,
          online_fn: fn -> ["Horse Dentist", "DigimonOtis"] end,
          dispatch_fn: fn persona, assignment ->
            send(test, {:dispatched, persona, assignment})
          end,
          seeds_fn: fn ->
            Agent.get_and_update(topic_agent, fn
              [] -> {"a fallback topic", []}
              [h | t] -> {h, t}
            end)
          end
        )

      # one assign cycle dispatches to an online persona
      Scheduler.tick_assign(sched)
      assert_receive {:dispatched, persona, %{id: id, board: board, topic: topic}}
      assert persona in ["Horse Dentist", "DigimonOtis"]
      assert board in Boards.Core.boards()

      # the persona's host returns a good post → pending, not yet on the boards
      Scheduler.deliver(sched, id, "a genuinely fine and sufficiently long board post")
      assert %{pending: 1} = eventually_stats(sched)
      assert Boards.hot(boards, board) == []

      # drip releases it to the boards
      Scheduler.tick_drip(sched)
      assert [%{topic: ^topic, author: ^persona}] = Boards.hot(boards, board)

      # a refusal is dropped, never reaches pending
      Scheduler.tick_assign(sched)
      assert_receive {:dispatched, _p, %{id: id2}}
      Scheduler.deliver(sched, id2, "I can't help with that.")
      assert %{pending: 0} = eventually_stats(sched)
    end

    test "no online personas → nothing dispatched", %{boards: boards} do
      test = self()

      {:ok, sched} =
        Scheduler.start_link(
          name: nil,
          manual: true,
          enabled: true,
          boards: boards,
          online_fn: fn -> [] end,
          dispatch_fn: fn p, a -> send(test, {:dispatched, p, a}) end,
          seeds_fn: fn -> "topic" end
        )

      Scheduler.tick_assign(sched)
      refute_receive {:dispatched, _, _}, 50
    end
  end

  defp eventually_stats(sched), do: Scheduler.stats(sched)
end
