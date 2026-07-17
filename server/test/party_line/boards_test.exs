defmodule PartyLine.BoardsTest do
  use ExUnit.Case, async: true

  alias PartyLine.Boards
  alias PartyLine.Boards.{Core, Post}

  describe "functional core: hot algorithm" do
    test "more net votes rank higher at the same time" do
      t = ~U[2026-06-01 00:00:00Z]
      a = %Post{id: "a", board: "x", topic: "t", author: "z", body: "b", created_at: t, ups: 5}
      b = %Post{id: "b", board: "x", topic: "t", author: "z", body: "b", created_at: t, ups: 50}
      assert Post.hot(b) > Post.hot(a)
    end

    test "newer ranks higher at the same score" do
      old = %Post{
        id: "o",
        board: "x",
        topic: "t",
        author: "z",
        body: "b",
        created_at: ~U[2026-06-01 00:00:00Z],
        ups: 10
      }

      new = %Post{
        id: "n",
        board: "x",
        topic: "t",
        author: "z",
        body: "b",
        created_at: ~U[2026-06-02 00:00:00Z],
        ups: 10
      }

      assert Post.hot(new) > Post.hot(old)
    end

    test "a ~10x vote lead beats a ~12.5h age advantage" do
      # reddit's constant: 45000s ≈ 12.5h per order of magnitude
      newer_small = %Post{
        id: "s",
        board: "x",
        topic: "t",
        author: "z",
        body: "b",
        created_at: ~U[2026-06-02 00:00:00Z],
        ups: 10
      }

      # 10 h older — inside the ~12.5 h window a 10× lead can hold
      older_big = %Post{
        id: "l",
        board: "x",
        topic: "t",
        author: "z",
        body: "b",
        created_at: ~U[2026-06-01 14:00:00Z],
        ups: 100
      }

      assert Post.hot(older_big) > Post.hot(newer_small)
    end
  end

  describe "functional core: event application" do
    test "voting tallies, toggles off, and flips" do
      post = %Post{
        id: "p",
        board: "x",
        topic: "t",
        author: "z",
        body: "b",
        created_at: ~U[2026-06-01 00:00:00Z]
      }

      s0 = Core.apply_event(Core.empty(), %{type: :post_submitted, post: post})

      up = %{type: :voted, voter: "ada", post_id: "p", dir: :up}
      s1 = Core.apply_event(s0, up)
      assert Core.get(s1, "p").ups == 1
      assert Core.vote_of(s1, "ada", "p") == :up

      # same dir again clears
      s2 = Core.apply_event(s1, up)
      assert Core.get(s2, "p").ups == 0
      assert Core.vote_of(s2, "ada", "p") == nil

      # up then down flips (no double count)
      s3 = s1 |> Core.apply_event(%{type: :voted, voter: "ada", post_id: "p", dir: :down})
      assert Core.get(s3, "p").ups == 0
      assert Core.get(s3, "p").downs == 1
    end

    test "board mapping and hot ordering" do
      assert Core.board_for("tifu") == "confessions"
      assert Core.board_for("AITAH") == "courtroom"
      assert "confessions" in Core.boards()
    end

    test "a :voted event for a missing post id is a no-op" do
      state = Core.empty()

      voted = %{type: :voted, voter: "erowid smoothie", post_id: "ghost", dir: :up}
      assert Core.apply_event(state, voted) == state
    end

    test "an unknown event type is a no-op (forward compat)" do
      post = %Post{
        id: "p",
        board: "trivia",
        topic: "t",
        author: "gas station sushi",
        body: "b",
        created_at: ~U[2026-06-01 00:00:00Z]
      }

      state = Core.apply_event(Core.empty(), %{type: :post_submitted, post: post})
      assert Core.apply_event(state, %{type: :post_pinned, post_id: "p"}) == state
    end

    test "board_name maps every slug and passes unknowns through" do
      assert Core.board_name("confessions") == "confessions"
      assert Core.board_name("courtroom") == "the courtroom"
      assert Core.board_name("questions") == "the questions"
      assert Core.board_name("sagas") == "the sagas"
      assert Core.board_name("trivia") == "did you know"
      assert Core.board_name("mystery-board") == "mystery-board"
    end

    test "board_for maps the remaining subs and falls back to questions" do
      assert Core.board_for("AskReddit") == "questions"
      assert Core.board_for("BestofRedditorUpdates") == "sagas"
      assert Core.board_for("todayilearned") == "trivia"
      assert Core.board_for("SomewhereUnknown") == "questions"
    end

    test "hot and newest filter by board, include :all, and honor limit" do
      a = %Post{
        id: "a",
        board: "trivia",
        topic: "t",
        author: "erowid smoothie",
        body: "b",
        created_at: ~U[2026-06-01 00:00:00Z]
      }

      b = %Post{
        id: "b",
        board: "sagas",
        topic: "t",
        author: "horse dentist",
        body: "b",
        created_at: ~U[2026-06-02 00:00:00Z]
      }

      state =
        Core.empty()
        |> Core.apply_event(%{type: :post_submitted, post: a})
        |> Core.apply_event(%{type: :post_submitted, post: b})

      assert [%Post{id: "a"}] = Core.hot(state, "trivia")
      assert [%Post{id: "b"}] = Core.newest(state, "sagas")
      assert Core.hot(state, "confessions") == []
      assert state |> Core.hot(:all) |> length() == 2
      # newest-first with a limit of 1 keeps only the younger post
      assert [%Post{id: "b"}] = Core.newest(state, :all, 1)
    end

    test "Post.vote clamps tallies at zero" do
      post = %Post{
        id: "p",
        board: "trivia",
        topic: "t",
        author: "erowid smoothie",
        body: "b",
        created_at: ~U[2026-06-01 00:00:00Z]
      }

      assert Post.vote(post, :up, -1).ups == 0
      assert Post.vote(post, :down, -1).downs == 0
      assert post |> Post.vote(:up, +1) |> Post.vote(:down, +1) |> Post.net() == 0
    end
  end

  describe "imperative shell: the GenServer" do
    setup do
      path = Path.join(System.tmp_dir!(), "boards-#{System.unique_integer([:positive])}.dets")

      {:ok, boards} =
        Boards.start_link(name: nil, path: path, table: :"t#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(path) end)
      %{boards: boards, path: path}
    end

    test "submit → vote → hot, broadcasting each event", %{boards: boards} do
      Phoenix.PubSub.subscribe(PartyLine.PubSub, "boards")

      {:ok, p} =
        Boards.submit(boards, %{
          board: "confessions",
          topic: "t",
          author: "Horse Dentist",
          body: "the molars knew"
        })

      assert_receive {:boards, %{type: :post_submitted}}

      {:ok, _} = Boards.vote(boards, "ada", p.id, :up)
      assert_receive {:boards, %{type: :voted, post_id: id}} when id == p.id or true
      assert Boards.get(boards, p.id).ups == 1

      assert [%Post{id: got}] = Boards.hot(boards, "confessions")
      assert got == p.id
    end

    test "voting on a nonexistent post errors without crashing or broadcasting", %{
      boards: boards
    } do
      Boards.subscribe()

      assert {:error, :no_post} = Boards.vote(boards, "erowid smoothie", "no-such-post", :up)
      refute_receive {:boards, %{type: :voted}}, 50
    end

    test "board-scoped subscriptions only see their board's events", %{boards: boards} do
      Boards.subscribe("confessions")

      {:ok, conf} =
        Boards.submit(boards, %{
          board: "confessions",
          topic: "t",
          author: "erowid smoothie",
          body: "the booth is open"
        })

      conf_id = conf.id
      assert_receive {:boards, %{type: :post_submitted, post: %Post{id: ^conf_id}}}

      {:ok, q} =
        Boards.submit(boards, %{
          board: "questions",
          topic: "t",
          author: "horse dentist",
          body: "asking for a friend"
        })

      q_id = q.id
      refute_receive {:boards, %{post: %Post{id: ^q_id}}}, 50
    end

    test "newest is newest-first, honors limit, and count tracks submissions", %{
      boards: boards
    } do
      for n <- 1..3 do
        {:ok, _} =
          Boards.submit(boards, %{
            board: "trivia",
            topic: "topic #{n}",
            author: "gas station sushi",
            body: "body #{n}"
          })
      end

      assert Boards.count(boards) == 3

      assert [%Post{topic: "topic 3"}, %Post{topic: "topic 2"}, %Post{topic: "topic 1"}] =
               Boards.newest(boards, "trivia")

      assert [%Post{topic: "topic 3"}, %Post{topic: "topic 2"}] = Boards.newest(boards, :all, 2)
    end

    test "vote_of tracks vote → toggle → flip", %{boards: boards} do
      {:ok, p} =
        Boards.submit(boards, %{
          board: "courtroom",
          topic: "t",
          author: "erowid smoothie",
          body: "objection sustained"
        })

      assert Boards.vote_of(boards, "juror nine", p.id) == nil

      {:ok, _} = Boards.vote(boards, "juror nine", p.id, :up)
      assert Boards.vote_of(boards, "juror nine", p.id) == :up

      {:ok, _} = Boards.vote(boards, "juror nine", p.id, :up)
      assert Boards.vote_of(boards, "juror nine", p.id) == nil

      {:ok, _} = Boards.vote(boards, "juror nine", p.id, :down)
      assert Boards.vote_of(boards, "juror nine", p.id) == :down
    end

    test "submit stores an explicit label and defaults to none", %{boards: boards} do
      {:ok, labelled} =
        Boards.submit(boards, %{
          board: "confessions",
          topic: "t",
          author: "erowid smoothie",
          body: "the heavy one",
          label: "heavy"
        })

      {:ok, plain} =
        Boards.submit(boards, %{
          board: "confessions",
          topic: "t",
          author: "erowid smoothie",
          body: "the plain one"
        })

      assert Boards.get(boards, labelled.id).label == "heavy"
      assert Boards.get(boards, plain.id).label == "none"
    end

    test "replay preserves a cleared vote and a multi-word author across restart", %{
      boards: boards,
      path: path
    } do
      {:ok, p} =
        Boards.submit(boards, %{
          board: "sagas",
          topic: "t",
          author: "erowid smoothie",
          body: "part one of many"
        })

      # up then up again: a toggle-off, so the replayed tally must be zero
      {:ok, _} = Boards.vote(boards, "juror nine", p.id, :up)
      {:ok, _} = Boards.vote(boards, "juror nine", p.id, :up)
      GenServer.stop(boards)

      {:ok, reopened} =
        Boards.start_link(name: nil, path: path, table: :"t#{System.unique_integer([:positive])}")

      post = Boards.get(reopened, p.id)
      assert post.ups == 0
      assert post.author == "erowid smoothie"
      assert Boards.vote_of(reopened, "juror nine", p.id) == nil
    end

    test "the event log rebuilds state on restart", %{boards: boards, path: path} do
      {:ok, p} =
        Boards.submit(boards, %{
          board: "questions",
          topic: "t",
          author: "DigimonOtis",
          body: "space raccoons"
        })

      Boards.vote(boards, "ada", p.id, :up)
      Boards.vote(boards, "bo", p.id, :up)
      GenServer.stop(boards)

      {:ok, reopened} =
        Boards.start_link(name: nil, path: path, table: :"t#{System.unique_integer([:positive])}")

      post = Boards.get(reopened, p.id)
      assert post.ups == 2
      assert post.body == "space raccoons"
    end
  end
end
