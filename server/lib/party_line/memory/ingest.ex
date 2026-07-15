defmodule PartyLine.Memory.Ingest do
  @moduledoc """
  Serializes ROOT CHAT TREE ingestion into the central deciduous graph.

  Every room message and presence event is cast here (never a call — the room
  must never block on the network) and posted, one at a time, to the deciduous
  API via `PartyLine.Memory.Client`. A per-room chain of "follows" edges keeps
  each room's transcript linear; mentions get their own get-or-create
  participant node so a name is a single node reused across the conversation.

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
       ensured: false,
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
    with {:ok, state} <- ensure(state),
         {:ok, node_id, state} <- add(state, message_args(room_id, message)),
         {:ok, state} <- follow(state, room_id, node_id),
         {:ok, state} <- mentions(state, room_id, node_id, Map.get(message, :mentions, [])) do
      state
    else
      {:dropped, state} -> state
    end
  end

  defp do_presence(state, room_id, event, participant) do
    with {:ok, state} <- ensure(state),
         {:ok, node_id, state} <- add(state, presence_args(room_id, event, participant)),
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
           {:ok, state} <- link(state, msg_node, pnode, "mentions") do
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

        case add(state, args) do
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

  defp ensure(%{ensured: true} = state), do: {:ok, state}

  defp ensure(state) do
    case Client.ensure_graph(state.config) do
      :ok -> {:ok, %{state | ensured: true}}
      {:error, reason} -> {:dropped, warn(reason, state)}
    end
  end

  defp add(state, args) do
    case Client.add_node(state.config, args) do
      {:ok, node_id} -> {:ok, node_id, state}
      {:error, reason} -> {:dropped, warn(reason, state)}
    end
  end

  defp link(state, from_id, to_id, rationale) do
    case Client.link_nodes(state.config, %{from_id: from_id, to_id: to_id, rationale: rationale}) do
      :ok -> {:ok, state}
      {:error, reason} -> {:dropped, warn(reason, state)}
    end
  end

  # Chain the new node onto the room's tail with a "follows" edge, then make it
  # the new tail. The first node of a room has no predecessor.
  defp follow(state, room_id, node_id) do
    prev = Map.get(state.last, room_id)

    result = if prev, do: link(state, prev, node_id, "follows"), else: {:ok, state}

    case result do
      {:ok, state} -> {:ok, %{state | last: Map.put(state.last, room_id, node_id)}}
      {:dropped, state} -> {:dropped, state}
    end
  end

  defp warn(reason, state) do
    Logger.warning("PartyLine.Memory.Ingest dropped event: #{inspect(reason)}")
    state
  end
end
