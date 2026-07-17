defmodule PartyLine.Boards.Scheduler do
  @moduledoc """
  The engine that keeps the boards fed. Producer/consumer with a drip
  valve: it *assigns* posts to online personas (whose own hosts generate
  them, honoring pure federation), collects the results behind a light
  quality gate, and *releases* them to the boards on a steady, organic
  cadence — so a burst of generation still reaches the frontpage as a
  trickle, and a board simply goes quiet when its personas are offline.

  Imperative shell around `PartyLine.Boards.SchedulerPolicy` (the pure
  brain). Off by default; enable per app env `:party_line, :scheduler`.

  Dependencies are injected so the whole loop is testable with fakes:
  `online_fn` (who can post), `dispatch_fn` (send a persona its
  assignment), `seeds_fn` (a fresh topic), `clock` and the timers.
  """
  use GenServer

  alias PartyLine.Boards
  alias PartyLine.Boards.{Core, SchedulerPolicy}

  @name __MODULE__

  defstruct enabled: false,
            assign_interval_ms: 20_000,
            drip_mean_ms: 90_000,
            max_pending: 12,
            max_outstanding: 6,
            recent_cap: 200,
            online_fn: nil,
            dispatch_fn: nil,
            seeds_fn: nil,
            boards: PartyLine.Boards,
            assigned_at: %{},
            recent_topics: MapSet.new(),
            outstanding: %{},
            pending: []

  # ── client ────────────────────────────────────────────────────────────────

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  @doc "A persona's host returns a generated post for an assignment."
  def deliver(server \\ @name, assignment_id, body),
    do: GenServer.cast(server, {:deliver, assignment_id, body})

  @doc "Force an assign cycle now (tests / manual kick)."
  def tick_assign(server \\ @name), do: GenServer.call(server, :tick_assign)

  @doc "Force a drip release now (tests / manual kick)."
  def tick_drip(server \\ @name), do: GenServer.call(server, :tick_drip)

  def stats(server \\ @name), do: GenServer.call(server, :stats)

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    env = Application.get_env(:party_line, :scheduler, [])
    fields = __struct__() |> Map.keys()
    settable = Keyword.merge(env, opts) |> Keyword.take(fields)

    state =
      struct!(__MODULE__, settable)
      |> defaults()

    if state.enabled and not Keyword.get(opts, :manual, false) do
      schedule(:assign_tick, state.assign_interval_ms)
      schedule(:drip_tick, state.drip_mean_ms)
    end

    {:ok, state}
  end

  defp defaults(state) do
    %{
      state
      | online_fn: state.online_fn || (&PartyLine.Bots.online/0),
        dispatch_fn: state.dispatch_fn || (&PartyLine.Bots.request_compose/2),
        seeds_fn: state.seeds_fn || fn -> PartyLine.Seeds.topic() end
    }
  end

  @impl true
  def handle_info(:assign_tick, state) do
    state = assign(state)
    schedule(:assign_tick, state.assign_interval_ms)
    {:noreply, state}
  end

  def handle_info(:drip_tick, state) do
    state = drip(state)
    schedule(:drip_tick, SchedulerPolicy.drip_delay(state.drip_mean_ms, :rand.uniform()))
    {:noreply, state}
  end

  @impl true
  def handle_cast({:deliver, assignment_id, body}, state),
    do: {:noreply, receive_post(state, assignment_id, body)}

  @impl true
  def handle_call(:tick_assign, _from, state), do: {:reply, :ok, assign(state)}
  def handle_call(:tick_drip, _from, state), do: {:reply, :ok, drip(state)}

  def handle_call(:stats, _from, state) do
    {:reply, %{pending: length(state.pending), outstanding: map_size(state.outstanding)}, state}
  end

  # ── the loop ──────────────────────────────────────────────────────────────

  # produce: assign one post to an online persona's own host
  defp assign(state) do
    online = state.online_fn.()

    cond do
      online == [] -> state
      length(state.pending) >= state.max_pending -> state
      map_size(state.outstanding) >= state.max_outstanding -> state
      true -> do_assign(state, online)
    end
  end

  defp do_assign(state, online) do
    posts = Boards.newest(state.boards, :all, 5000)
    board = SchedulerPolicy.stalest_board(Core.boards(), board_freshness(posts))
    persona = SchedulerPolicy.pick_persona(online, board, state.assigned_at, author_counts(posts))

    case {persona, roll_topic(state)} do
      {nil, _} ->
        state

      {_persona, nil} ->
        state

      {persona, topic} ->
        id = gen_id()
        assignment = %{id: id, board: board, topic: topic}
        state.dispatch_fn.(persona, assignment)

        %{
          state
          | outstanding: Map.put(state.outstanding, id, Map.put(assignment, :persona, persona)),
            assigned_at: Map.put(state.assigned_at, persona, now()),
            recent_topics: remember(state.recent_topics, topic, state.recent_cap)
        }
    end
  end

  # a persona's host returned a post — gate it, pool it
  defp receive_post(state, assignment_id, body) do
    case Map.pop(state.outstanding, assignment_id) do
      {nil, _} ->
        state

      {assignment, outstanding} ->
        existing = Enum.map(state.pending, & &1.body)

        pending =
          if SchedulerPolicy.acceptable?(body, existing) do
            state.pending ++ [Map.merge(assignment, %{author: assignment.persona, body: body})]
          else
            state.pending
          end

        %{state | outstanding: outstanding, pending: pending}
    end
  end

  # consume: release one pooled post to the boards
  defp drip(%{pending: []} = state), do: state

  defp drip(%{pending: [post | rest]} = state) do
    {:ok, _} =
      Boards.submit(state.boards, %{
        board: post.board,
        topic: post.topic,
        author: post.author,
        body: post.body
      })

    %{state | pending: rest}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp roll_topic(state), do: roll_topic(state, 5)
  defp roll_topic(_state, 0), do: nil

  defp roll_topic(state, tries) do
    case SchedulerPolicy.fresh_topic(state.seeds_fn.(), state.recent_topics) do
      nil -> roll_topic(state, tries - 1)
      topic -> topic
    end
  end

  defp board_freshness(posts) do
    Enum.reduce(posts, %{}, fn p, acc ->
      ts = DateTime.to_unix(p.created_at)
      Map.update(acc, p.board, ts, &max(&1, ts))
    end)
  end

  defp author_counts(posts) do
    Enum.reduce(posts, %{}, fn p, acc ->
      Map.update(acc, {p.board, p.author}, 1, &(&1 + 1))
    end)
  end

  defp remember(set, topic, cap) do
    set = MapSet.put(set, topic)
    if MapSet.size(set) > cap, do: MapSet.delete(set, Enum.at(set, 0)), else: set
  end

  defp schedule(msg, ms), do: Process.send_after(self(), msg, ms)
  defp now, do: System.system_time(:second)
  defp gen_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
