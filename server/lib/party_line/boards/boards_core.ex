defmodule PartyLine.Boards.Core do
  @moduledoc """
  The boards' functional core: pure functions over an immutable state map,
  plus event application. No processes, no I/O — the imperative shell
  (`PartyLine.Boards`) owns those and calls in here.

  State is `%{posts: %{id => Post}, votes: %{{voter, post_id} => :up|:down}}`.
  Events are plain maps `%{type: ..., ...}`; `apply_event/2` folds one in.
  This is what an event log replays through to rebuild state.
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

  def empty, do: %{posts: %{}, votes: %{}}

  # ── event application (the reducer) ───────────────────────────────────────

  @doc "Fold one event into state. Unknown/duplicate events are no-ops."
  def apply_event(state, %{type: :post_submitted, post: %Post{} = post}) do
    put_in(state.posts[post.id], post)
  end

  def apply_event(state, %{type: :voted, voter: voter, post_id: post_id, dir: dir}) do
    case state.posts[post_id] do
      nil ->
        state

      post ->
        key = {voter, post_id}
        prev = state.votes[key]
        {post, votes} = retally(post, votes_after(state.votes, key, prev, dir), prev, dir)
        %{state | posts: Map.put(state.posts, post_id, post), votes: votes}
    end
  end

  def apply_event(state, _unknown), do: state

  # toggling: same dir again clears the vote; opposite dir flips it
  defp votes_after(votes, key, prev, dir) when prev == dir, do: Map.delete(votes, key)
  defp votes_after(votes, key, _prev, dir), do: Map.put(votes, key, dir)

  defp retally(post, votes, prev, dir) do
    post =
      post
      |> undo(prev)
      |> redo(prev, dir)

    {post, votes}
  end

  defp undo(post, nil), do: post
  defp undo(post, :up), do: Post.vote(post, :up, -1)
  defp undo(post, :down), do: Post.vote(post, :down, -1)

  # if the new dir equals prev, it was a toggle-off (already undone, add nothing)
  defp redo(post, prev, dir) when prev == dir, do: post
  defp redo(post, _prev, :up), do: Post.vote(post, :up, +1)
  defp redo(post, _prev, :down), do: Post.vote(post, :down, +1)

  # ── queries (pure) ────────────────────────────────────────────────────────

  @doc "Posts on a board (or :all), hottest first."
  def hot(state, board \\ :all, limit \\ 50) do
    state.posts
    |> Map.values()
    |> filter_board(board)
    |> Enum.sort_by(&Post.hot/1, :desc)
    |> Enum.take(limit)
  end

  @doc "Newest posts first."
  def newest(state, board \\ :all, limit \\ 50) do
    state.posts
    |> Map.values()
    |> filter_board(board)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  def get(state, id), do: state.posts[id]

  @doc "How a voter has voted on a post (:up | :down | nil)."
  def vote_of(state, voter, post_id), do: state.votes[{voter, post_id}]

  def count(state), do: map_size(state.posts)

  defp filter_board(posts, :all), do: posts
  defp filter_board(posts, board), do: Enum.filter(posts, &(&1.board == board))
end
