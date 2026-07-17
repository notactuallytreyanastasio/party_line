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

    test "pick_board: empty boards first, then stalest, ties by name, nil when boardless" do
      boards = ~w(a b c)
      # regression: the old :nil_low sentinel sorted AFTER integers, so a
      # never-posted board lost to any timestamped one
      assert SchedulerPolicy.pick_board(boards, %{"a" => 1000, "c" => 5000}) == "b"
      assert SchedulerPolicy.pick_board(boards, %{"a" => 1000, "b" => 9000, "c" => 5000}) == "a"
      # two empty boards tie → first by name
      assert SchedulerPolicy.pick_board(boards, %{"a" => 1000}) == "b"
      assert SchedulerPolicy.pick_board([], %{}) == nil
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

    test "nobody online → no persona" do
      assert SchedulerPolicy.pick_persona([], "confessions", %{}, %{}) == nil
    end

    test "persona pick works with multi-word lowercase handles" do
      online = ["erowid smoothie", "horse dentist", "gas station sushi"]

      counts = %{
        {"confessions", "erowid smoothie"} => 2,
        {"confessions", "horse dentist"} => 1
      }

      assert SchedulerPolicy.pick_persona(online, "confessions", %{}, counts) ==
               "gas station sushi"

      # tie at 0 posts → least recently assigned, tuple ordering intact
      assigned = %{"erowid smoothie" => 50, "horse dentist" => 10}

      assert SchedulerPolicy.pick_persona(
               ["erowid smoothie", "horse dentist"],
               "trivia",
               assigned,
               %{}
             ) == "horse dentist"
    end

    test "a nil body never passes the gate" do
      refute SchedulerPolicy.acceptable?(nil, [])
    end

    test "refusal gate is case-insensitive and anchored to the start" do
      refute SchedulerPolicy.acceptable?("I CANNOT do that, no matter how nicely you ask", [])
      refute SchedulerPolicy.acceptable?("I'M SORRY but the raccoons said no", [])
      # a marker mid-string is not a refusal
      assert SchedulerPolicy.acceptable?(
               "they told me i can't post this, so here it is anyway",
               []
             )
    end

    test "fresh_topic with exhausted seeds (nil candidate) is nil" do
      assert SchedulerPolicy.fresh_topic(nil, MapSet.new(["anything at all"])) == nil
    end

    test "near-duplicate signature is only the first 60 normalized chars" do
      # 72 chars of identical normalized prefix, then diverging tails
      prefix = "the raccoons met at midnight to divide the trash by weight and seniority"
      first = prefix <> " and it went fine"
      second = prefix <> " but the possum objected loudly"

      refute SchedulerPolicy.acceptable?(second, [first])

      assert SchedulerPolicy.acceptable?("a completely different post about vending machines", [
               first
             ])
    end

    test "drip delay is an integer ms and rejects u outside (0, 1]" do
      assert is_integer(SchedulerPolicy.drip_delay(1234, 0.37))

      assert_raise FunctionClauseError, fn -> SchedulerPolicy.drip_delay(1000, 0) end
      assert_raise FunctionClauseError, fn -> SchedulerPolicy.drip_delay(1000, 1.5) end
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

    test "max_outstanding backpressure gates a second assign", %{boards: boards} do
      sched = start_sched(boards, max_outstanding: 1)

      Scheduler.tick_assign(sched)
      assert_receive {:dispatched, _persona, _assignment}

      Scheduler.tick_assign(sched)
      refute_receive {:dispatched, _, _}, 50
      assert %{outstanding: 1, pending: 0} = Scheduler.stats(sched)
    end

    test "max_pending backpressure gates further assigns", %{boards: boards} do
      sched = start_sched(boards, max_pending: 1)

      Scheduler.tick_assign(sched)
      assert_receive {:dispatched, _persona, %{id: id}}
      Scheduler.deliver(sched, id, "a perfectly acceptable long enough post body")
      assert %{pending: 1, outstanding: 0} = Scheduler.stats(sched)

      Scheduler.tick_assign(sched)
      refute_receive {:dispatched, _, _}, 50
      assert %{pending: 1, outstanding: 0} = Scheduler.stats(sched)
    end

    test "deliver for an unknown assignment id is a no-op", %{boards: boards} do
      sched = start_sched(boards)

      Scheduler.deliver(sched, "no-such-assignment", "a long body that would otherwise pass fine")
      assert %{pending: 0, outstanding: 0} = Scheduler.stats(sched)
      assert Boards.newest(boards, :all) == []
    end

    test "a delivered near-duplicate of a pending post is gated out", %{boards: boards} do
      sched = start_sched(boards)

      Scheduler.tick_assign(sched)
      assert_receive {:dispatched, _p1, %{id: id1}}
      Scheduler.deliver(sched, id1, "the molars have always known the truth about us")
      assert %{pending: 1} = Scheduler.stats(sched)

      Scheduler.tick_assign(sched)
      assert_receive {:dispatched, _p2, %{id: id2}}
      Scheduler.deliver(sched, id2, "The Molars Have Always KNOWN the truth about us!!!")
      assert %{pending: 1, outstanding: 0} = Scheduler.stats(sched)
    end

    test "tick_drip with nothing pending is a no-op", %{boards: boards} do
      sched = start_sched(boards)

      assert Scheduler.tick_drip(sched) == :ok
      assert %{pending: 0, outstanding: 0} = Scheduler.stats(sched)
      assert Boards.newest(boards, :all) == []
    end

    test "a seeds_fn stuck on an already-used topic exhausts the re-roll", %{boards: boards} do
      sched =
        start_sched(boards, seeds_fn: fn -> "the only topic anyone remembers" end)

      Scheduler.tick_assign(sched)
      assert_receive {:dispatched, _p, %{topic: "the only topic anyone remembers"}}

      # the topic is now recent; five re-rolls all hit it → assignment skipped
      Scheduler.tick_assign(sched)
      refute_receive {:dispatched, _, _}, 50
      assert %{outstanding: 1, pending: 0} = Scheduler.stats(sched)
    end

    test "drip releases pending posts FIFO", %{boards: boards} do
      sched = start_sched(boards)

      Scheduler.tick_assign(sched)
      assert_receive {:dispatched, _pa, %{id: id1}}
      Scheduler.tick_assign(sched)
      assert_receive {:dispatched, _pb, %{id: id2}}

      Scheduler.deliver(sched, id1, "first body: raccoons unionize behind the dumpster")
      Scheduler.deliver(sched, id2, "second body: the vending machine owes me an apology")
      assert %{pending: 2} = Scheduler.stats(sched)

      Scheduler.tick_drip(sched)
      assert %{pending: 1} = Scheduler.stats(sched)

      assert [%{body: "first body: raccoons unionize behind the dumpster"}] =
               Boards.newest(boards, :all)

      Scheduler.tick_drip(sched)
      assert %{pending: 0} = Scheduler.stats(sched)
      assert length(Boards.newest(boards, :all)) == 2
    end

    test "assign steers to the stalest (empty) board", %{boards: boards} do
      for b <- Boards.Core.boards() -- ["sagas"] do
        {:ok, _} =
          Boards.submit(boards, %{
            board: b,
            topic: "filler",
            author: "erowid smoothie",
            body: "filler body"
          })
      end

      sched = start_sched(boards)

      Scheduler.tick_assign(sched)
      assert_receive {:dispatched, _persona, %{board: "sagas"}}
    end
  end

  defp eventually_stats(sched), do: Scheduler.stats(sched)

  defp start_sched(boards, opts \\ []) do
    test = self()

    {:ok, sched} =
      Scheduler.start_link(
        Keyword.merge(
          [
            name: nil,
            manual: true,
            enabled: true,
            boards: boards,
            online_fn: fn -> ["erowid smoothie", "horse dentist"] end,
            dispatch_fn: fn persona, assignment ->
              send(test, {:dispatched, persona, assignment})
            end,
            seeds_fn:
              topic_stream([
                "topic the first",
                "topic the second",
                "topic the third",
                "topic the fourth"
              ])
          ],
          opts
        )
      )

    sched
  end

  defp topic_stream(topics) do
    {:ok, agent} = Agent.start_link(fn -> topics end)

    fn ->
      Agent.get_and_update(agent, fn
        [] -> {"a bottomless fallback topic", []}
        [h | t] -> {h, t}
      end)
    end
  end
end
