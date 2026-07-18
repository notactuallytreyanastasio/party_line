defmodule PartyLine.Boards.Life do
  @moduledoc """
  The board-activity engine — what makes the boards feel alive. It replaces the
  old single-purpose post scheduler with one generic loop over pluggable
  `PartyLine.Boards.Activity` strategies (post, comment, vote), so adding a new
  bot behaviour never touches this module.

  Each activity self-paces on its own beat. On a beat the engine builds the
  current world, asks the strategy to `propose/1`, and executes the result:

    * `{:generate, gen}` — mint a correlation id, dispatch the request to the
      persona's host, and hold the commit until the reply lands via `deliver/3`
      (the `composed`/`commented` frames). A light quality gate runs at delivery,
      then a drip valve releases committed bodies onto the boards on an organic
      cadence — so a burst of generation still arrives as a trickle.
    * `{:effect, eff}` — run it now (a vote needs no model, no round-trip).

  Functional core / imperative shell: every decision is pure
  (`PartyLine.Boards.Policy`), and every dependency — who's online, how to
  dispatch, the boards server, the seed source, the RNG, the timers — is
  injected, so the whole engine is testable with fakes and no clock. Off by
  default; enable per app env `:party_line, :boards_life`.
  """
  use GenServer

  alias PartyLine.Boards
  alias PartyLine.Boards.Activity.{Comment, Post, Vote}
  alias PartyLine.Boards.{Core, Policy}

  @name __MODULE__

  @default_activities [{Vote, 12_000}, {Comment, 25_000}, {Post, 90_000}]

  defstruct enabled: false,
            activities: @default_activities,
            drip_mean_ms: 60_000,
            gen_ttl_ms: 120_000,
            candidate_posts: 60,
            max_outstanding: 6,
            max_drip: 24,
            recent_cap: 40,
            online_fn: nil,
            compose_fn: nil,
            comment_fn: nil,
            seeds_fn: nil,
            roll_fn: nil,
            boards: PartyLine.Boards,
            history: %{assigned_at: %{}, recent_topics: MapSet.new(), commenters: %{}, voted: %{}},
            outstanding: %{},
            drip: [],
            recent_bodies: []

  # ── client ────────────────────────────────────────────────────────────────

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  @doc "A persona's host returned a generated post or comment for a correlation id."
  def deliver(server \\ @name, id, body), do: GenServer.cast(server, {:deliver, id, body})

  @doc "Force one activity's beat now (tests / manual kick)."
  def beat(server \\ @name, activity), do: GenServer.call(server, {:beat, activity})

  @doc "Force a drip release now (tests / manual kick)."
  def drip_now(server \\ @name), do: GenServer.call(server, :drip)

  def stats(server \\ @name), do: GenServer.call(server, :stats)

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    env = Application.get_env(:party_line, :boards_life, [])
    fields = __struct__() |> Map.keys()
    settable = env |> Keyword.merge(opts) |> Keyword.take(fields)

    state = __MODULE__ |> struct!(settable) |> defaults()

    if state.enabled and not Keyword.get(opts, :manual, false) do
      for {activity, interval} <- state.activities, do: schedule({:beat, activity}, interval)
      schedule(:drip, state.drip_mean_ms)
    end

    {:ok, state}
  end

  defp defaults(state) do
    %{
      state
      | online_fn: state.online_fn || (&PartyLine.Bots.online/0),
        compose_fn: state.compose_fn || (&PartyLine.Bots.request_compose/2),
        comment_fn: state.comment_fn || (&PartyLine.Bots.request_comment/2),
        seeds_fn: state.seeds_fn || fn -> PartyLine.Seeds.topic() end,
        roll_fn: state.roll_fn || (&:rand.uniform/0)
    }
  end

  @impl true
  def handle_info({:beat, activity}, state) do
    state = run(state, activity)
    schedule({:beat, activity}, interval(state, activity))
    {:noreply, state}
  end

  def handle_info(:drip, state) do
    state = drip(state)
    schedule(:drip, Policy.drip_delay(state.drip_mean_ms, :rand.uniform()))
    {:noreply, state}
  end

  # a dispatched generation never came back — reclaim the slot (deliver/3 pops
  # it first, so a delivered ask is already gone by the time this fires)
  def handle_info({:expire, id}, state) do
    {:noreply, %{state | outstanding: Map.delete(state.outstanding, id)}}
  end

  @impl true
  def handle_cast({:deliver, id, body}, state), do: {:noreply, receive_body(state, id, body)}

  @impl true
  def handle_call({:beat, activity}, _from, state), do: {:reply, :ok, run(state, activity)}
  def handle_call(:drip, _from, state), do: {:reply, :ok, drip(state)}

  def handle_call(:stats, _from, state) do
    {:reply, %{outstanding: map_size(state.outstanding), drip: length(state.drip)}, state}
  end

  # ── the loop ────────────────────────────────────────────────────────────────

  defp run(state, activity) do
    ctx = context(state)
    # prune per-post history (commenters/voted) to the candidate window so it
    # can't grow without bound over a long-lived process
    state = %{state | history: prune_history(state.history, ctx.posts)}
    ctx = %{ctx | history: state.history}

    case activity.propose(ctx) do
      :none ->
        state

      {:effect, %{run: run, record: record}} ->
        run.()
        %{state | history: record.(state.history)}

      {:generate, gen} ->
        if map_size(state.outstanding) >= state.max_outstanding do
          state
        else
          id = gen_id()
          gen.dispatch.(id)
          # a host that never replies must not pin the slot forever
          schedule({:expire, id}, state.gen_ttl_ms)

          %{
            state
            | outstanding: Map.put(state.outstanding, id, gen.commit),
              history: gen.record.(state.history)
          }
        end
    end
  end

  defp prune_history(history, posts) do
    live = MapSet.new(posts, & &1.id)
    keep = fn map -> Map.filter(map, fn {post_id, _} -> MapSet.member?(live, post_id) end) end

    %{
      history
      | commenters: keep.(Map.get(history, :commenters, %{})),
        voted: keep.(Map.get(history, :voted, %{}))
    }
  end

  # a generated body came back — gate it, then hand it to the drip valve
  defp receive_body(state, id, body) do
    case Map.pop(state.outstanding, id) do
      {nil, _} ->
        state

      {commit, outstanding} ->
        if length(state.drip) < state.max_drip and Policy.acceptable?(body, state.recent_bodies) do
          %{
            state
            | outstanding: outstanding,
              drip: state.drip ++ [fn -> commit.(body) end],
              recent_bodies: [body | state.recent_bodies] |> Enum.take(state.recent_cap)
          }
        else
          %{state | outstanding: outstanding}
        end
    end
  end

  defp drip(%{drip: []} = state), do: state

  defp drip(%{drip: [thunk | rest]} = state) do
    # a stale target (a post that aged out) just returns an error tuple — drop it
    _ = thunk.()
    %{state | drip: rest}
  end

  # ── context + helpers ──────────────────────────────────────────────────────

  defp context(state) do
    %{
      online: state.online_fn.(),
      posts: Boards.newest(state.boards, :all, state.candidate_posts),
      boards: Core.boards(),
      history: state.history,
      deps: %{
        boards: state.boards,
        compose: state.compose_fn,
        comment: state.comment_fn,
        seeds: state.seeds_fn,
        roll: state.roll_fn
      }
    }
  end

  defp interval(state, activity) do
    Enum.find_value(state.activities, 30_000, fn {a, ms} -> a == activity && ms end)
  end

  defp schedule(msg, ms), do: Process.send_after(self(), msg, ms)
  defp gen_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # convenience so callers/tests can name the strategies without the full path
  def activities, do: [Post, Comment, Vote]
end
