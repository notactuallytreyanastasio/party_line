defmodule PartyLine.Boards.Core do
  @moduledoc """
  The boards' functional core: pure functions over lists of posts, plus the
  board metadata. No processes, no I/O, no persistence — the shell
  (`PartyLine.Boards`) owns Postgres and the ETS cache and calls in here to
  rank and label.

  Ranking runs over whatever list the shell pulls out of the cache; this is
  the same reddit-shaped `hot` order the frontpage shows, kept pure so it's
  trivial to test without a database.
  """

  alias PartyLine.Boards.Post

  @boards ~w(confessions courtroom questions sagas trivia)

  @doc "The fixed set of board slugs."
  def boards, do: @boards

  @doc "Human-facing name for a board slug."
  def board_name("confessions"), do: "confessions"
  def board_name("courtroom"), do: "the courtroom"
  def board_name("questions"), do: "the questions"
  def board_name("sagas"), do: "the sagas"
  def board_name("trivia"), do: "did you know"
  def board_name(other), do: other

  @doc "Map a seed's source subreddit to a board slug."
  def board_for("AskReddit"), do: "questions"
  def board_for("AITAH"), do: "courtroom"
  def board_for("tifu"), do: "confessions"
  def board_for("BestofRedditorUpdates"), do: "sagas"
  def board_for("todayilearned"), do: "trivia"
  def board_for(_), do: "questions"

  # ── ranking (pure) ─────────────────────────────────────────────────────────

  @doc "Posts on a board (or :all), hottest first."
  def hot(posts, board \\ :all, limit \\ 50) do
    posts
    |> filter_board(board)
    |> Enum.sort_by(&Post.hot/1, :desc)
    |> Enum.take(limit)
  end

  @doc "Newest posts first."
  def newest(posts, board \\ :all, limit \\ 50) do
    posts
    |> filter_board(board)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc "Comments oldest-first — thread reading order."
  def thread(comments), do: Enum.sort_by(comments, & &1.created_at, {:asc, DateTime})

  defp filter_board(posts, :all), do: posts
  defp filter_board(posts, board), do: Enum.filter(posts, &(&1.board == board))
end
