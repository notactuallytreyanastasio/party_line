defmodule PartyLine.BoardsTest do
  use PartyLine.DataCase

  alias PartyLine.Boards
  alias PartyLine.Boards.{Comment, Core, Post}

  # a bare post struct for the pure ranking tests — no DB, no tally plumbing
  defp post(attrs) do
    struct!(
      %Post{
        id: "p",
        board: "trivia",
        topic: "t",
        author: "erowid smoothie",
        body: "b",
        created_at: ~U[2026-06-01 00:00:00Z]
      },
      attrs
    )
  end

  describe "functional core: hot algorithm" do
    test "more net votes rank higher at the same time" do
      t = ~U[2026-06-01 00:00:00Z]

      assert Post.hot(post(id: "b", created_at: t, ups: 50)) >
               Post.hot(post(id: "a", created_at: t, ups: 5))
    end

    test "newer ranks higher at the same score" do
      old = post(id: "o", created_at: ~U[2026-06-01 00:00:00Z], ups: 10)
      new = post(id: "n", created_at: ~U[2026-06-02 00:00:00Z], ups: 10)
      assert Post.hot(new) > Post.hot(old)
    end

    test "a ~10x vote lead beats a ~12.5h age advantage" do
      # reddit's constant: 45000s ≈ 12.5h per order of magnitude
      newer_small = post(id: "s", created_at: ~U[2026-06-02 00:00:00Z], ups: 10)
      # 10 h older — inside the ~12.5 h window a 10× lead can hold
      older_big = post(id: "l", created_at: ~U[2026-06-01 14:00:00Z], ups: 100)
      assert Post.hot(older_big) > Post.hot(newer_small)
    end

    test "Post.vote clamps tallies at zero" do
      p = post([])
      assert Post.vote(p, :up, -1).ups == 0
      assert Post.vote(p, :down, -1).downs == 0
      assert p |> Post.vote(:up, +1) |> Post.vote(:down, +1) |> Post.net() == 0
    end
  end

  describe "functional core: ranking and board metadata" do
    test "board_name maps every slug and passes unknowns through" do
      assert Core.board_name("confessions") == "confessions"
      assert Core.board_name("courtroom") == "the courtroom"
      assert Core.board_name("questions") == "the questions"
      assert Core.board_name("sagas") == "the sagas"
      assert Core.board_name("trivia") == "did you know"
      assert Core.board_name("mystery-board") == "mystery-board"
    end

    test "board_for maps the subs and falls back to questions" do
      assert Core.board_for("tifu") == "confessions"
      assert Core.board_for("AITAH") == "courtroom"
      assert Core.board_for("AskReddit") == "questions"
      assert Core.board_for("BestofRedditorUpdates") == "sagas"
      assert Core.board_for("todayilearned") == "trivia"
      assert Core.board_for("SomewhereUnknown") == "questions"
      assert "confessions" in Core.boards()
    end

    test "hot and newest filter by board, include :all, and honor limit" do
      a = post(id: "a", board: "trivia", created_at: ~U[2026-06-01 00:00:00Z])
      b = post(id: "b", board: "sagas", created_at: ~U[2026-06-02 00:00:00Z])
      posts = [a, b]

      assert [%Post{id: "a"}] = Core.hot(posts, "trivia")
      assert [%Post{id: "b"}] = Core.newest(posts, "sagas")
      assert Core.hot(posts, "confessions") == []
      assert posts |> Core.hot(:all) |> length() == 2
      # newest-first with a limit of 1 keeps only the younger post
      assert [%Post{id: "b"}] = Core.newest(posts, :all, 1)
    end

    test "thread reads comments oldest-first regardless of input order" do
      c1 = %Comment{
        id: "c1",
        post_id: "p",
        author: "z",
        body: "first",
        created_at: ~U[2026-06-01 00:00:01Z]
      }

      c2 = %Comment{
        id: "c2",
        post_id: "p",
        author: "z",
        body: "second",
        created_at: ~U[2026-06-01 00:00:02Z]
      }

      assert Enum.map(Core.thread([c2, c1]), & &1.body) == ["first", "second"]
    end
  end

  describe "the shell: Postgres source of truth, ETS read cache" do
    setup do
      {:ok, boards} = Boards.start_link(name: nil)
      %{boards: boards}
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
      assert_receive {:boards, %{type: :voted, post_id: id}} when id == p.id
      assert Boards.get(boards, p.id).ups == 1

      assert [%Post{id: got}] = Boards.hot(boards, "confessions")
      assert got == p.id
    end

    test "a submitted post is durable in Postgres, not just the cache", %{boards: boards} do
      {:ok, p} =
        Boards.submit(boards, %{
          board: "trivia",
          topic: "t",
          author: "gas station sushi",
          body: "the row is real"
        })

      # a brand-new instance warms its cache from the same (sandboxed) DB and
      # sees the post — proof it was persisted, not held only in the first cache
      {:ok, other} = Boards.start_link(name: nil)
      assert Boards.get(other, p.id).body == "the row is real"
    end

    test "invalid submit is rejected by the draft, nothing persisted", %{boards: boards} do
      assert {:error, %Ecto.Changeset{}} =
               Boards.submit(boards, %{board: "not-a-board", topic: "t", author: "z", body: "b"})

      assert {:error, %Ecto.Changeset{}} =
               Boards.submit(boards, %{board: "trivia", author: "z", body: "b"})

      assert Boards.count(boards) == 0
    end

    test "voting on a nonexistent post errors without crashing or broadcasting", %{
      boards: boards
    } do
      Phoenix.PubSub.subscribe(PartyLine.PubSub, "boards")

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

    test "vote_of tracks vote → toggle → flip, and the tally follows", %{boards: boards} do
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
      assert Boards.get(boards, p.id).ups == 1

      {:ok, _} = Boards.vote(boards, "juror nine", p.id, :up)
      assert Boards.vote_of(boards, "juror nine", p.id) == nil
      assert Boards.get(boards, p.id).ups == 0

      {:ok, _} = Boards.vote(boards, "juror nine", p.id, :down)
      assert Boards.vote_of(boards, "juror nine", p.id) == :down
      assert Boards.get(boards, p.id).downs == 1
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

    test "a toggle-off leaves a zero tally and a multi-word author intact", %{boards: boards} do
      {:ok, p} =
        Boards.submit(boards, %{
          board: "sagas",
          topic: "t",
          author: "erowid smoothie",
          body: "part one of many"
        })

      # up then up again is a toggle-off, so the tally lands back at zero
      {:ok, _} = Boards.vote(boards, "juror nine", p.id, :up)
      {:ok, _} = Boards.vote(boards, "juror nine", p.id, :up)

      post = Boards.get(boards, p.id)
      assert post.ups == 0
      assert post.author == "erowid smoothie"
      assert Boards.vote_of(boards, "juror nine", p.id) == nil
    end

    test "comment → broadcast → read", %{boards: boards} do
      Phoenix.PubSub.subscribe(PartyLine.PubSub, "boards")

      {:ok, post} =
        Boards.submit(boards, %{
          board: "confessions",
          topic: "t",
          author: "Horse Dentist",
          body: "the molars knew"
        })

      assert_receive {:boards, %{type: :post_submitted}}

      {:ok, c} =
        Boards.comment(boards, %{post_id: post.id, author: "erowid smoothie", body: "big if true"})

      assert_receive {:boards, %{type: :comment_added, comment: %Comment{id: id}}} when id == c.id
      assert Boards.comment_count(boards, post.id) == 1

      assert [%Comment{body: "big if true", author: "erowid smoothie"}] =
               Boards.comments(boards, post.id)
    end

    test "commenting on a nonexistent post errors without crashing", %{boards: boards} do
      assert {:error, :no_post} =
               Boards.comment(boards, %{post_id: "ghost", author: "x", body: "hello?"})
    end

    test "a blank comment is rejected by the draft", %{boards: boards} do
      {:ok, post} =
        Boards.submit(boards, %{
          board: "trivia",
          topic: "t",
          author: "gas station sushi",
          body: "b"
        })

      assert {:error, %Ecto.Changeset{}} =
               Boards.comment(boards, %{post_id: post.id, author: "z", body: "   "})

      assert Boards.comment_count(boards, post.id) == 0
    end
  end
end
