defmodule PartyLine.Boards.LifeTest do
  # non-async: the shell drives a Boards instance that persists to Postgres,
  # so it runs under a shared-mode sandbox.
  use PartyLine.DataCase

  alias PartyLine.Boards
  alias PartyLine.Boards.Activity
  alias PartyLine.Boards.Life

  setup do
    {:ok, boards} = Boards.start_link(name: nil)
    %{boards: boards}
  end

  defp start_life(boards, opts \\ []) do
    test = self()

    {:ok, life} =
      Life.start_link(
        Keyword.merge(
          [
            name: nil,
            manual: true,
            enabled: true,
            boards: boards,
            online_fn: fn -> ["erowid smoothie", "horse dentist"] end,
            compose_fn: fn persona, assignment -> send(test, {:compose, persona, assignment}) end,
            comment_fn: fn persona, task -> send(test, {:comment, persona, task}) end,
            roll_fn: fn -> 0.1 end,
            seeds_fn: topic_stream(["topic one", "topic two", "topic three", "topic four"])
          ],
          opts
        )
      )

    life
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

  describe "posts (the Post activity)" do
    test "beat → dispatch → deliver → drip lands a post; the gate holds", %{boards: boards} do
      life = start_life(boards)

      Life.beat(life, Activity.Post)
      assert_receive {:compose, persona, %{id: id, board: board, topic: topic}}
      assert persona in ["erowid smoothie", "horse dentist"]
      assert board in Boards.Core.boards()

      # a good body pools in the drip valve, not yet on the boards
      Life.deliver(life, id, "a genuinely fine and sufficiently long board post")
      assert %{drip: 1} = Life.stats(life)
      assert Boards.hot(boards, board) == []

      # the drip releases it
      Life.drip_now(life)
      assert [%{topic: ^topic, author: ^persona}] = Boards.hot(boards, board)

      # a refusal never makes the drip
      Life.beat(life, Activity.Post)
      assert_receive {:compose, _p, %{id: id2}}
      Life.deliver(life, id2, "I can't help with that.")
      assert %{drip: 0} = Life.stats(life)
    end

    test "no online personas → nothing dispatched", %{boards: boards} do
      life = start_life(boards, online_fn: fn -> [] end)
      Life.beat(life, Activity.Post)
      refute_receive {:compose, _, _}, 50
    end

    test "max_outstanding backpressure gates a second generation", %{boards: boards} do
      life = start_life(boards, max_outstanding: 1)

      Life.beat(life, Activity.Post)
      assert_receive {:compose, _, _}

      Life.beat(life, Activity.Post)
      refute_receive {:compose, _, _}, 50
      assert %{outstanding: 1} = Life.stats(life)
    end

    test "deliver for an unknown id is a no-op", %{boards: boards} do
      life = start_life(boards)
      Life.deliver(life, "no-such-id", "a long body that would otherwise pass fine")
      assert %{outstanding: 0, drip: 0} = Life.stats(life)
      assert Boards.newest(boards, :all) == []
    end

    test "a near-duplicate of a pooled body is gated out", %{boards: boards} do
      life = start_life(boards)

      Life.beat(life, Activity.Post)
      assert_receive {:compose, _p1, %{id: id1}}
      Life.deliver(life, id1, "the molars have always known the truth about us")
      assert %{drip: 1} = Life.stats(life)

      Life.beat(life, Activity.Post)
      assert_receive {:compose, _p2, %{id: id2}}
      Life.deliver(life, id2, "The Molars Have Always KNOWN the truth about us!!!")
      assert %{drip: 1} = Life.stats(life)
    end

    test "drip releases pooled posts FIFO", %{boards: boards} do
      life = start_life(boards)

      Life.beat(life, Activity.Post)
      assert_receive {:compose, _pa, %{id: id1}}
      Life.beat(life, Activity.Post)
      assert_receive {:compose, _pb, %{id: id2}}

      Life.deliver(life, id1, "first body: raccoons unionize behind the dumpster")
      Life.deliver(life, id2, "second body: the vending machine owes me an apology")
      assert %{drip: 2} = Life.stats(life)

      Life.drip_now(life)

      assert [%{body: "first body: raccoons unionize behind the dumpster"}] =
               Boards.newest(boards, :all)

      Life.drip_now(life)
      assert length(Boards.newest(boards, :all)) == 2
    end

    test "steers to the stalest (empty) board", %{boards: boards} do
      for b <- Boards.Core.boards() -- ["sagas"] do
        {:ok, _} =
          Boards.submit(boards, %{
            board: b,
            topic: "filler",
            author: "gas station sushi",
            body: "filler body"
          })
      end

      life = start_life(boards)
      Life.beat(life, Activity.Post)
      assert_receive {:compose, _persona, %{board: "sagas"}}
    end

    test "a seeds_fn stuck on a used topic exhausts the re-roll and skips", %{boards: boards} do
      life = start_life(boards, seeds_fn: fn -> "the only topic anyone remembers" end)

      Life.beat(life, Activity.Post)
      assert_receive {:compose, _p, %{topic: "the only topic anyone remembers"}}

      Life.beat(life, Activity.Post)
      refute_receive {:compose, _, _}, 50
    end
  end

  describe "comments (the Comment activity)" do
    test "beat picks a real post, dispatches, and drips a reply onto the thread", %{
      boards: boards
    } do
      {:ok, post} =
        Boards.submit(boards, %{
          board: "sagas",
          topic: "t",
          author: "erowid smoothie",
          body: "the post body"
        })

      # only horse dentist online — not the author, so it's the one eligible
      life = start_life(boards, online_fn: fn -> ["horse dentist"] end)

      Life.beat(life, Activity.Comment)

      assert_receive {:comment, "horse dentist",
                      %{id: id, post_id: post_id, body: "the post body"}}

      assert post_id == post.id

      Life.deliver(life, id, "naming the starter was the correct move")
      Life.drip_now(life)

      assert Boards.comment_count(boards, post.id) == 1

      assert [%{author: "horse dentist", body: "naming the starter was the correct move"}] =
               Boards.comments(boards, post.id)
    end

    test "nobody but the author is online → no comment", %{boards: boards} do
      {:ok, _post} =
        Boards.submit(boards, %{board: "sagas", topic: "t", author: "ada", body: "the post body"})

      life = start_life(boards, online_fn: fn -> ["ada"] end)
      Life.beat(life, Activity.Comment)
      refute_receive {:comment, _, _}, 50
    end
  end

  describe "votes (the Vote activity)" do
    test "beat casts a server-side vote, and never double-votes", %{boards: boards} do
      {:ok, post} =
        Boards.submit(boards, %{
          board: "sagas",
          topic: "t",
          author: "erowid smoothie",
          body: "the post"
        })

      # roll < up_bias → an upvote, cast as the online persona
      life = start_life(boards, online_fn: fn -> ["horse dentist"] end, roll_fn: fn -> 0.1 end)

      Life.beat(life, Activity.Vote)
      assert Boards.get(boards, post.id).ups == 1
      assert Boards.vote_of(boards, "horse dentist", post.id) == :up

      # the same persona won't vote the same post twice — the score holds
      Life.beat(life, Activity.Vote)
      assert Boards.get(boards, post.id).ups == 1
    end

    test "a high roll casts a downvote", %{boards: boards} do
      {:ok, post} =
        Boards.submit(boards, %{board: "trivia", topic: "t", author: "ada", body: "the post"})

      life = start_life(boards, online_fn: fn -> ["bo"] end, roll_fn: fn -> 0.99 end)
      Life.beat(life, Activity.Vote)
      assert Boards.get(boards, post.id).downs == 1
    end
  end
end
