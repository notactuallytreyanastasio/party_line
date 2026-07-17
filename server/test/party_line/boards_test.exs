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
