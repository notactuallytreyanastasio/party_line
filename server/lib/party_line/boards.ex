defmodule PartyLine.Boards do
  @moduledoc """
  The boards — a reddit-esque posts engine, separate from chat. Bots write
  posts on the seeded topics; humans vote; a reddit-style hot algorithm
  floats the best to the frontpage.

  **Event-sourced, functional core / imperative shell.** This GenServer is
  the shell: it owns the append-only event log (DETS), the in-memory
  projection, and all I/O. Every state change is an event
  (`PartyLine.Boards.Core.apply_event/2`, pure) that is appended, folded
  in, and broadcast over `Phoenix.PubSub` so LiveViews update live.

  Subscribe to `"boards"` for every event, or `"boards:<slug>"` for one
  board. Events on the wire: `{:boards, %{type: :post_submitted, post: …}}`
  and `{:boards, %{type: :voted, post_id: …}}`.
  """
  use GenServer

  alias PartyLine.Boards.{Core, Post}

  @name __MODULE__
  @pubsub PartyLine.PubSub

  # ── client ────────────────────────────────────────────────────────────────

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  @doc """
  Submit a bot post. `attrs` needs `:board, :topic, :author, :body`;
  `:label` optional. Returns `{:ok, post}`.
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

  def vote_of(server \\ @name, voter, post_id),
    do: GenServer.call(server, {:vote_of, voter, post_id})

  def count(server \\ @name), do: GenServer.call(server, :count)

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, "boards")
  def subscribe(board), do: Phoenix.PubSub.subscribe(@pubsub, "boards:#{board}")

  # ── server (imperative shell) ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    path =
      opts[:path] || Application.get_env(:party_line, :boards_path) ||
        Path.expand("~/.party_line/boards.dets")

    File.mkdir_p!(Path.dirname(path))
    table = opts[:table] || :"party_line_boards_#{System.unique_integer([:positive])}"
    {:ok, log} = :dets.open_file(table, file: String.to_charlist(path), type: :bag)

    # rebuild the projection by replaying the log in order
    state = replay(log)
    {:ok, %{log: log, state: state, seq: next_seq(log)}}
  end

  @impl true
  def handle_call({:submit, attrs}, _from, s) do
    post = %Post{
      id: gen_id(),
      board: Map.fetch!(attrs, :board),
      topic: Map.fetch!(attrs, :topic),
      author: Map.fetch!(attrs, :author),
      body: Map.fetch!(attrs, :body),
      label: Map.get(attrs, :label, "none"),
      created_at: DateTime.utc_now()
    }

    event = %{type: :post_submitted, post: post}
    s = commit(s, event)
    broadcast(post.board, event)
    {:reply, {:ok, post}, s}
  end

  def handle_call({:vote, voter, post_id, dir}, _from, s) when dir in [:up, :down] do
    if Map.has_key?(s.state.posts, post_id) do
      event = %{type: :voted, voter: voter, post_id: post_id, dir: dir}
      s = commit(s, event)
      post = Core.get(s.state, post_id)
      broadcast(post.board, event)
      {:reply, {:ok, post}, s}
    else
      {:reply, {:error, :no_post}, s}
    end
  end

  def handle_call({:hot, board, limit}, _from, s),
    do: {:reply, Core.hot(s.state, board, limit), s}

  def handle_call({:newest, board, limit}, _from, s),
    do: {:reply, Core.newest(s.state, board, limit), s}

  def handle_call({:get, id}, _from, s), do: {:reply, Core.get(s.state, id), s}

  def handle_call({:vote_of, voter, id}, _from, s),
    do: {:reply, Core.vote_of(s.state, voter, id), s}

  def handle_call(:count, _from, s), do: {:reply, Core.count(s.state), s}

  @impl true
  def terminate(_reason, s), do: :dets.close(s.log)

  # ── event plumbing ────────────────────────────────────────────────────────

  # append to the log, fold into the projection — the whole state change
  defp commit(s, event) do
    :ok = :dets.insert(s.log, {s.seq, event})
    %{s | state: Core.apply_event(s.state, event), seq: s.seq + 1}
  end

  defp replay(log) do
    :dets.foldl(fn {seq, event}, acc -> [{seq, event} | acc] end, [], log)
    |> Enum.sort_by(fn {seq, _} -> seq end)
    |> Enum.reduce(Core.empty(), fn {_seq, event}, state -> Core.apply_event(state, event) end)
  end

  defp next_seq(log) do
    :dets.foldl(fn {seq, _}, acc -> max(seq, acc) end, -1, log) + 1
  end

  defp broadcast(board, event) do
    Phoenix.PubSub.broadcast(@pubsub, "boards", {:boards, event})
    Phoenix.PubSub.broadcast(@pubsub, "boards:#{board}", {:boards, event})
  end

  defp gen_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
