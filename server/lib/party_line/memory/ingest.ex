defmodule PartyLine.Memory.Ingest do
  @moduledoc """
  Living memory: one deciduous graph per room.

  Every room message and presence event is cast here (never a call — the room
  must never block on the network) and posted, one at a time, to the deciduous
  API via `PartyLine.Memory.Client`. A chain of "follows" edges keeps each
  room's transcript linear; mentions get their own get-or-create participant
  node so a name is a single node reused across the conversation.

  ## Why a graph per room, not one for the exchange

  A room is a conversation with its own topic, its own regulars, and its own
  thread of "what happened". Folding every line into one graph would make the
  most interesting question — *what does this room remember?* — a filtering
  problem forever after, and would make a room's memory impossible to hand to
  anyone (or delete) on its own. The room id *is* the graph id: it already
  satisfies deciduous's `[a-z0-9_-]` rule, so there is no mapping to keep
  honest.

  Failure is expected, not exceptional: the daemon may be down. Any client
  error is logged once and the event is DROPPED — the JSONL transcript in
  `PartyLine.TranscriptLog` is the flight-recorder fallback, and the room
  never notices. When `:enabled` is false the process still runs but no-ops,
  so callers need no conditional wiring.
  """

  use GenServer
  require Logger

  alias PartyLine.Memory.Client

  @truncate 100

  # ── Client API ───────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Record a committed room message. Cast — never blocks the room."
  def record_message(server \\ __MODULE__, room_id, message) do
    safe_cast(server, {:record_message, room_id, message})
  end

  @doc "Record a presence event (`:joined | :left | :announced`). Cast."
  def record_presence(server \\ __MODULE__, room_id, event, participant) do
    safe_cast(server, {:record_presence, room_id, event, participant})
  end

  # Guard so a not-started Ingest never crashes the caller.
  defp safe_cast(server, msg) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, msg)
    end
  end

  # ── Server ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    env = Application.get_env(:party_line, :memory, [])
    enabled = Keyword.get(opts, :enabled, Keyword.get(env, :enabled, false))

    config =
      Keyword.get(opts, :config) ||
        %{
          api_url: Keyword.get(env, :api_url),
          token: Keyword.get(env, :token),
          graph: Keyword.get(env, :root_graph, "party-line-root")
        }

    {:ok,
     %{
       enabled: enabled,
       config: config,
       # graphs we've created this run; a room earns its graph on first event
       ensured: MapSet.new(),
       # room_id => last node id (the tail of that room's "follows" chain)
       last: %{},
       # {room_id, name} => participant node id
       participants: %{}
     }}
  end

  # A synchronous no-op so tests (and any caller) can wait for the cast queue
  # to drain before asserting.
  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast(_msg, %{enabled: false} = state), do: {:noreply, state}

  def handle_cast({:record_message, room_id, message}, state) do
    {:noreply, do_message(state, room_id, message)}
  end

  def handle_cast({:record_presence, room_id, event, participant}, state) do
    {:noreply, do_presence(state, room_id, event, participant)}
  end

  # ── Ingestion ────────────────────────────────────────────────────────────

  defp do_message(state, room_id, message) do
    with {:ok, state} <- ensure(state, room_id),
         {:ok, node_id, state} <- add(state, room_id, message_args(room_id, message)),
         {:ok, state} <- follow(state, room_id, node_id),
         {:ok, state} <- mentions(state, room_id, node_id, Map.get(message, :mentions, [])) do
      state
    else
      {:dropped, state} -> state
    end
  end

  defp do_presence(state, room_id, event, participant) do
    with {:ok, state} <- ensure(state, room_id),
         {:ok, node_id, state} <- add(state, room_id, presence_args(room_id, event, participant)),
         {:ok, state} <- follow(state, room_id, node_id) do
      state
    else
      {:dropped, state} -> state
    end
  end

  # Get-or-create one participant node per (room, name), then link message ->
  # participant with "mentions". Stops (and drops the rest) on the first error.
  defp mentions(state, room_id, msg_node, mentions) do
    Enum.reduce_while(mentions, {:ok, state}, fn mention, {:ok, state} ->
      with {:ok, pnode, state} <- ensure_participant(state, room_id, mention),
           {:ok, state} <- link(state, room_id, msg_node, pnode, "mentions") do
        {:cont, {:ok, state}}
      else
        {:dropped, state} -> {:halt, {:dropped, state}}
      end
    end)
  end

  defp ensure_participant(state, room_id, %{name: name} = mention) do
    key = {room_id, name}

    case Map.get(state.participants, key) do
      nil ->
        kind = Map.get(mention, :kind)

        args = %{
          node_type: "observation",
          title: "participant: #{name} (#{kind})",
          branch: room_id
        }

        case add(state, room_id, args) do
          {:ok, node_id, state} ->
            {:ok, node_id, %{state | participants: Map.put(state.participants, key, node_id)}}

          {:dropped, state} ->
            {:dropped, state}
        end

      node_id ->
        {:ok, node_id, state}
    end
  end

  # ── Node/edge shapes ─────────────────────────────────────────────────────

  defp message_args(room_id, message) do
    sender_name = get_in(message, [:sender, :name]) || "?"
    body = Map.get(message, :body, "")

    %{
      node_type: "observation",
      title: "#{sender_name}: #{truncate(body)}",
      description: body,
      branch: room_id,
      prompt: nil
    }
  end

  defp presence_args(room_id, event, participant) do
    name = Map.get(participant, :name, "?")

    %{
      node_type: "observation",
      title: "presence: #{event} #{name}",
      branch: room_id
    }
  end

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, @truncate)
  defp truncate(_), do: ""

  # ── Client plumbing — each step returns {:ok, ...} | {:dropped, state} ────

  # The room id is the graph id. Rooms are already validated as
  # [a-z0-9][a-z0-9_-]* on the way in, which is exactly deciduous's rule.
  defp graph_for(state, room_id), do: %{state.config | graph: room_id}

  defp ensure(state, room_id) do
    if MapSet.member?(state.ensured, room_id) do
      {:ok, state}
    else
      case Client.ensure_graph(graph_for(state, room_id)) do
        :ok -> {:ok, %{state | ensured: MapSet.put(state.ensured, room_id)}}
        {:error, reason} -> {:dropped, warn(reason, state, room_id)}
      end
    end
  end

  defp add(state, room_id, args) do
    case Client.add_node(graph_for(state, room_id), args) do
      {:ok, node_id} -> {:ok, node_id, state}
      {:error, reason} -> {:dropped, warn(reason, state, room_id)}
    end
  end

  defp link(state, room_id, from_id, to_id, rationale) do
    config = graph_for(state, room_id)

    case Client.link_nodes(config, %{from_id: from_id, to_id: to_id, rationale: rationale}) do
      :ok -> {:ok, state}
      {:error, reason} -> {:dropped, warn(reason, state, room_id)}
    end
  end

  # Chain the new node onto the room's tail with a "follows" edge, then make it
  # the new tail. The first node of a room has no predecessor.
  defp follow(state, room_id, node_id) do
    prev = Map.get(state.last, room_id)

    result = if prev, do: link(state, room_id, prev, node_id, "follows"), else: {:ok, state}

    case result do
      {:ok, state} -> {:ok, %{state | last: Map.put(state.last, room_id, node_id)}}
      {:dropped, state} -> {:dropped, state}
    end
  end

  # A dropped event is a warning, not a crash — memory is a nicety and the
  # exchange keeps running without it. But a 404 means the graph we were
  # promised is gone (the daemon's data wiped, or its cache and its disk
  # disagreeing), and the `ensured` latch would otherwise keep us pointed at a
  # grave for the life of the server: every event after the first 404 dropped,
  # forever, with nothing but log spam to show for it. So un-latch and let the
  # next event re-create it. That is the difference between memory that is
  # merely enabled and memory that is alive.
  defp warn({:http_status, 404, _body} = reason, state, room_id) do
    Logger.warning(
      "PartyLine.Memory.Ingest: #{room_id}'s graph vanished, re-creating — #{inspect(reason)}"
    )

    %{
      state
      | ensured: MapSet.delete(state.ensured, room_id),
        last: Map.delete(state.last, room_id),
        participants:
          state.participants |> Enum.reject(&match?({{^room_id, _}, _}, &1)) |> Map.new()
    }
  end

  defp warn(reason, state, room_id) do
    Logger.warning("PartyLine.Memory.Ingest dropped #{room_id} event: #{inspect(reason)}")
    state
  end
end
