defmodule PartyLine.Boards do
  @moduledoc """
  The boards — a reddit-esque posts engine, separate from chat. Bots write
  posts on the seeded topics; humans vote and comment; a reddit-style hot
  algorithm floats the best to the frontpage.

  **Postgres is the source of truth; ETS is the read cache.** Every write
  (`submit`, `vote`, `comment`) runs through this GenServer: it persists to the
  Repo — vote toggles adjust the post's tally in the same transaction — then
  updates the cache and broadcasts over `Phoenix.PubSub` so LiveViews update
  live. Reads (`hot`, `newest`, `get`, `comments`, …) are served from the ETS
  cache, which is warmed from Postgres on boot. The in-between payloads are
  typed: submit attrs become a `PostDraft`, comment attrs a `CommentDraft`.

  Subscribe to `"boards"` for every event, or `"boards:<slug>"` for one
  board. Events on the wire: `{:boards, %{type: :post_submitted, post: …}}`,
  `{:boards, %{type: :voted, post_id: …}}`, and
  `{:boards, %{type: :comment_added, comment: …}}`.
  """
  use GenServer

  import Ecto.Query, only: [from: 2]

  alias PartyLine.Boards.{Comment, CommentDraft, Core, Post, PostDraft, Vote}
  alias PartyLine.Repo

  require Logger

  @name __MODULE__
  @pubsub PartyLine.PubSub

  # ── client ────────────────────────────────────────────────────────────────

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  @doc """
  Submit a bot post. `attrs` needs `:board, :topic, :author, :body`;
  `:label` optional. Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def submit(server \\ @name, attrs), do: GenServer.call(server, {:submit, attrs})

  @doc "Cast a vote. `dir` is :up | :down; voting the same way again clears it."
  def vote(server \\ @name, voter, post_id, dir),
    do: GenServer.call(server, {:vote, voter, post_id, dir})

  def hot(server \\ @name, board \\ :all, limit \\ 50),
    do: GenServer.call(server, {:hot, board, limit})

  def newest(server \\ @name, board \\ :all, limit \\ 50),
    do: GenServer.call(server, {:newest, board, limit})

  def get(server \\ @name, id), do: GenServer.call(server, {:get, id})

  @doc """
  Add a comment to a post. `attrs` needs `:post_id, :author, :body`. Returns
  `{:ok, comment}`, `{:error, :no_post}` if the post isn't on the boards, or
  `{:error, changeset}` on invalid input.
  """
  def comment(server \\ @name, attrs), do: GenServer.call(server, {:comment, attrs})

  @doc "A post's comments, oldest first."
  def comments(server \\ @name, post_id), do: GenServer.call(server, {:comments, post_id})

  @doc "How many comments a post has."
  def comment_count(server \\ @name, post_id),
    do: GenServer.call(server, {:comment_count, post_id})

  def vote_of(server \\ @name, voter, post_id),
    do: GenServer.call(server, {:vote_of, voter, post_id})

  def count(server \\ @name), do: GenServer.call(server, :count)

  @doc "Test/dev only: drop the cache so a fresh (sandboxed) DB shows through."
  def reset(server \\ @name), do: GenServer.call(server, :reset)

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, "boards")
  def subscribe(board), do: Phoenix.PubSub.subscribe(@pubsub, "boards:#{board}")

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    tables = %{
      posts: :ets.new(:boards_posts, [:set, :protected, read_concurrency: true]),
      comments: :ets.new(:boards_comments, [:set, :protected, read_concurrency: true]),
      votes: :ets.new(:boards_votes, [:set, :protected, read_concurrency: true])
    }

    {:ok, tables, {:continue, :warm}}
  end

  @impl true
  def handle_continue(:warm, s) do
    warm(s, 5)
    {:noreply, s}
  end

  @impl true
  def handle_info({:warm, attempts}, s) do
    warm(s, attempts)
    {:noreply, s}
  end

  # ── writes (persist → cache → broadcast) ───────────────────────────────────

  @impl true
  def handle_call({:submit, attrs}, _from, s) do
    with {:ok, draft} <- PostDraft.new(attrs),
         row = draft |> Map.from_struct() |> Map.put(:id, gen_id()),
         {:ok, post} <- %Post{} |> Post.changeset(row) |> Repo.insert() do
      :ets.insert(s.posts, {post.id, post})
      broadcast(post.board, %{type: :post_submitted, post: post})
      {:reply, {:ok, post}, s}
    else
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  def handle_call({:vote, voter, post_id, dir}, _from, s) when dir in [:up, :down] do
    case lookup_post(s, post_id) do
      nil ->
        {:reply, {:error, :no_post}, s}

      post ->
        prev = lookup_vote(s, voter, post_id)
        {:ok, post} = Repo.transaction(fn -> persist_vote(voter, post, prev, dir) end)
        cache_vote(s, voter, post_id, prev, dir)
        :ets.insert(s.posts, {post.id, post})
        broadcast(post.board, %{type: :voted, voter: voter, post_id: post_id, dir: dir})
        {:reply, {:ok, post}, s}
    end
  end

  def handle_call({:comment, attrs}, _from, s) do
    with {:ok, draft} <- CommentDraft.new(attrs),
         post when not is_nil(post) <- lookup_post(s, draft.post_id),
         row = %{id: gen_id(), post_id: draft.post_id, author: draft.author, body: draft.body},
         {:ok, comment} <- %Comment{} |> Comment.changeset(row) |> Repo.insert() do
      :ets.insert(s.comments, {comment.id, comment})
      broadcast(post.board, %{type: :comment_added, comment: comment})
      {:reply, {:ok, comment}, s}
    else
      nil -> {:reply, {:error, :no_post}, s}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  # ── reads (served from the cache) ──────────────────────────────────────────

  def handle_call({:hot, board, limit}, _from, s),
    do: {:reply, Core.hot(all_posts(s), board, limit), s}

  def handle_call({:newest, board, limit}, _from, s),
    do: {:reply, Core.newest(all_posts(s), board, limit), s}

  def handle_call({:get, id}, _from, s), do: {:reply, lookup_post(s, id), s}

  def handle_call({:comments, post_id}, _from, s),
    do: {:reply, comments_for(s, post_id), s}

  def handle_call({:comment_count, post_id}, _from, s),
    do: {:reply, length(comments_for(s, post_id)), s}

  def handle_call({:vote_of, voter, id}, _from, s),
    do: {:reply, lookup_vote(s, voter, id), s}

  def handle_call(:count, _from, s), do: {:reply, :ets.info(s.posts, :size), s}

  def handle_call(:reset, _from, s) do
    for t <- [s.posts, s.comments, s.votes], do: :ets.delete_all_objects(t)
    {:reply, :ok, s}
  end

  # ── persistence ────────────────────────────────────────────────────────────

  # toggle-off: same direction again clears the vote and undoes its tally
  defp persist_vote(voter, post, prev, dir) when prev == dir do
    Repo.delete_all(from(v in Vote, where: v.voter == ^voter and v.post_id == ^post.id))
    post |> Post.vote(dir, -1) |> save_tally()
  end

  # first vote: a new row and one tally step
  defp persist_vote(voter, post, nil, dir) do
    Repo.insert!(Vote.changeset(%Vote{}, %{voter: voter, post_id: post.id, dir: dir}))
    post |> Post.vote(dir, +1) |> save_tally()
  end

  # flip: rewrite the row's direction and swing the tally both ways
  defp persist_vote(voter, post, prev, dir) do
    Repo.update_all(
      from(v in Vote, where: v.voter == ^voter and v.post_id == ^post.id),
      set: [dir: dir, updated_at: DateTime.utc_now()]
    )

    post |> Post.vote(prev, -1) |> Post.vote(dir, +1) |> save_tally()
  end

  defp save_tally(%Post{} = post) do
    {:ok, post} =
      post
      |> Ecto.Changeset.change(ups: post.ups, downs: post.downs)
      |> Repo.update()

    post
  end

  # warm the cache from Postgres; if the DB isn't ready yet, retry with backoff
  # (bounded) rather than serving an empty board forever after a boot-time blip
  defp warm(s, attempts) do
    Enum.each(Repo.all(Post), &:ets.insert(s.posts, {&1.id, &1}))
    Enum.each(Repo.all(Comment), &:ets.insert(s.comments, {&1.id, &1}))
    Enum.each(Repo.all(Vote), &:ets.insert(s.votes, {{&1.voter, &1.post_id}, &1.dir}))
  rescue
    e ->
      if attempts > 0 do
        Logger.warning("boards cache warm failed, retrying: #{Exception.message(e)}")
        Process.send_after(self(), {:warm, attempts - 1}, 3_000)
      else
        Logger.error("boards cache warm gave up: #{Exception.message(e)}")
      end
  end

  # ── cache helpers ──────────────────────────────────────────────────────────

  defp all_posts(s), do: :ets.select(s.posts, [{{:_, :"$1"}, [], [:"$1"]}])

  defp lookup_post(s, id) do
    case :ets.lookup(s.posts, id) do
      [{^id, post}] -> post
      [] -> nil
    end
  end

  defp lookup_vote(s, voter, post_id) do
    case :ets.lookup(s.votes, {voter, post_id}) do
      [{_key, dir}] -> dir
      [] -> nil
    end
  end

  defp comments_for(s, post_id) do
    s.comments
    |> :ets.select([{{:_, :"$1"}, [], [:"$1"]}])
    |> Enum.filter(&(&1.post_id == post_id))
    |> Core.thread()
  end

  defp cache_vote(s, voter, post_id, prev, dir) when prev == dir,
    do: :ets.delete(s.votes, {voter, post_id})

  defp cache_vote(s, voter, post_id, _prev, dir),
    do: :ets.insert(s.votes, {{voter, post_id}, dir})

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp broadcast(board, event) do
    Phoenix.PubSub.broadcast(@pubsub, "boards", {:boards, event})
    Phoenix.PubSub.broadcast(@pubsub, "boards:#{board}", {:boards, event})
  end

  defp gen_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
