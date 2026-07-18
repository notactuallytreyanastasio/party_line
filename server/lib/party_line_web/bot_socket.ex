defmodule PartyLineWeb.BotSocket do
  @moduledoc """
  Raw JSON WebSocket transport for federated participants (bot harnesses,
  scripted clients). This is deliberately NOT a Phoenix Channel: the wire
  protocol must stay a plain one-JSON-object-per-frame contract that a
  Python client can speak without a channels library.

  In:  join, announce, bid, speak, leave
  Out: welcome, presence, message, beat, grant, grant_revoked,
       speak_rejected, error

  The first frame must be `join`. Room events arrive at this process as
  `{:party_line, map}` and are pushed as JSON.
  """

  @behaviour Phoenix.Socket.Transport

  alias PartyLine.Rooms
  alias PartyLine.Rooms.Room

  @impl true
  def child_spec(_opts) do
    # no process of our own; each connection is its own transport process
    %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}, restart: :transient}
  end

  @impl true
  def connect(_transport_info) do
    {:ok, %{room: nil, room_id: nil, participant_id: nil, name: nil}}
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_in({text, _opts}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => type} = msg} -> dispatch(type, msg, state)
      _ -> push_error(state, :bad_message, "frames must be JSON objects with a type")
    end
  end

  @impl true
  def handle_info({:party_line, event}, state) do
    {:push, {:text, Jason.encode!(event)}, state}
  end

  # the board-life engine asks this persona's host to write a post
  def handle_info({:compose, assignment}, state) do
    frame = %{
      type: :compose_request,
      assignment_id: assignment.id,
      board: assignment.board,
      topic: assignment.topic
    }

    {:push, {:text, Jason.encode!(frame)}, state}
  end

  # the board-life engine asks this persona's host to comment on a post
  def handle_info({:comment_task, task}, state) do
    frame = %{
      type: :comment_request,
      task_id: task.id,
      post_id: task.post_id,
      topic: task.topic,
      body: task.body
    }

    {:push, {:text, Jason.encode!(frame)}, state}
  end

  # someone on the chat side asked a question and the router picked this host
  def handle_info({:ask, ask}, state) do
    frame = %{type: :ask_request, ask_id: ask.id, prompt: ask.prompt}
    {:push, {:text, Jason.encode!(frame)}, state}
  end

  def handle_info({:memory_result, call_id, result}, state) do
    frame =
      case result do
        {:ok, value} ->
          %{type: :memory_result, call_id: call_id, ok: true, result: value}

        {:error, reason} ->
          %{type: :memory_result, call_id: call_id, ok: false, error: inspect(reason)}
      end

    {:push, {:text, Jason.encode!(frame)}, state}
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{room: room, participant_id: id}) when is_pid(room) and id != nil do
    if Process.alive?(room), do: Room.leave(room, id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Inbound dispatch ─────────────────────────────────────────────────────

  defp dispatch("join", msg, %{participant_id: nil} = state) do
    with {:ok, name} <- fetch_string(msg, "name"),
         {:ok, kind} <- fetch_kind(msg),
         room_id = Map.get(msg, "room_id", Rooms.default_room_id()),
         {:ok, room} <- Rooms.ensure_room(room_id),
         {:ok, welcome} <-
           Room.join(room, %{name: name, kind: kind, lurk: Map.get(msg, "lurk", false) == true}) do
      # A bot host on the line joins the agent directory: it can be asked to
      # write board posts, and routed a chat message. Capabilities are whatever
      # the host claims about its own machine — Card.new/2 clamps them.
      if kind == :bot do
        PartyLine.Bots.register(name, self(), Map.get(msg, "capabilities", %{}))
      end

      state = %{
        state
        | room: room,
          room_id: room_id,
          participant_id: welcome.participant_id,
          name: name
      }

      {:reply, :ok, {:text, Jason.encode!(welcome)}, state}
    else
      {:error, reason} ->
        push_error(state, :join_failed, to_string(reason))
    end
  end

  defp dispatch("join", _msg, state), do: push_error(state, :already_joined, "already joined")

  defp dispatch(_type, _msg, %{participant_id: nil} = state),
    do: push_error(state, :not_joined, "first frame must be join")

  defp dispatch("bid", msg, state) do
    with {:ok, beat_id} <- fetch_string(msg, "beat_id"),
         urge when is_number(urge) <- Map.get(msg, "urge") do
      Room.bid(state.room, state.participant_id, beat_id, urge / 1)
      {:ok, state}
    else
      _ -> push_error(state, :bad_message, "bid requires beat_id and numeric urge")
    end
  end

  defp dispatch("speak", msg, state) do
    case fetch_string(msg, "body") do
      {:ok, body} ->
        grant_id = Map.get(msg, "grant_id")
        Room.speak(state.room, state.participant_id, grant_id, body, Map.get(msg, "client_ref"))
        {:ok, state}

      _ ->
        push_error(state, :bad_message, "speak requires body")
    end
  end

  defp dispatch("announce", _msg, state) do
    Room.announce(state.room, state.participant_id)
    {:ok, state}
  end

  # a persona's host returns a generated board post
  defp dispatch("composed", msg, state) do
    with {:ok, id} <- fetch_string(msg, "assignment_id"),
         {:ok, body} <- fetch_string(msg, "body") do
      PartyLine.Boards.Life.deliver(id, body)
      {:ok, state}
    else
      _ -> push_error(state, :bad_message, "post requires assignment_id and body")
    end
  end

  # a persona's host returns a generated comment
  defp dispatch("commented", msg, state) do
    with {:ok, id} <- fetch_string(msg, "task_id"),
         {:ok, body} <- fetch_string(msg, "body") do
      PartyLine.Boards.Life.deliver(id, body)
      {:ok, state}
    else
      _ -> push_error(state, :bad_message, "comment requires task_id and body")
    end
  end

  # A persona's host reads or writes its room's shared memory. The room comes
  # from the socket's own state, never the frame: a bot cannot name a graph, so
  # it cannot touch a room it didn't join.
  #
  # Brokered in a Task so a slow daemon can't wedge the socket — a bot that is
  # waiting on memory must still be able to hear the room and take a grant.
  defp dispatch("memory_call", msg, state) do
    with {:ok, call_id} <- fetch_string(msg, "call_id"),
         {:ok, tool} <- fetch_string(msg, "tool") do
      args = Map.get(msg, "args", %{})
      socket = self()
      room_id = state.room_id

      Task.Supervisor.start_child(PartyLine.TaskSupervisor, fn ->
        send(socket, {:memory_result, call_id, PartyLine.Memory.Broker.call(room_id, tool, args)})
      end)

      {:ok, state}
    else
      _ -> push_error(state, :bad_message, "memory_call requires call_id and tool")
    end
  end

  # a persona's host streams a token (or run) for an in-flight answer. Advisory:
  # the authoritative `answered` frame still closes the ask with the full body.
  defp dispatch("answer_delta", msg, state) do
    with {:ok, id} <- fetch_string(msg, "ask_id"),
         {:ok, delta} <- fetch_string(msg, "delta") do
      PartyLine.Asks.deliver_delta(id, delta)
      {:ok, state}
    else
      _ -> push_error(state, :bad_message, "answer_delta requires ask_id and delta")
    end
  end

  # a persona's host returns an answer to a chat question
  defp dispatch("answered", msg, state) do
    with {:ok, id} <- fetch_string(msg, "ask_id"),
         {:ok, body} <- fetch_string(msg, "body") do
      PartyLine.Asks.deliver(id, body)
      {:ok, state}
    else
      _ -> push_error(state, :bad_message, "answer requires ask_id and body")
    end
  end

  defp dispatch("leave", _msg, state) do
    Room.leave(state.room, state.participant_id)
    {:stop, :normal, state}
  end

  defp dispatch(type, _msg, state),
    do: push_error(state, :unknown_type, "unknown message type #{inspect(type)}")

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp fetch_string(msg, key) do
    case msg[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "missing #{key}"}
    end
  end

  defp fetch_kind(%{"kind" => "bot"}), do: {:ok, :bot}
  defp fetch_kind(%{"kind" => "human"}), do: {:ok, :human}
  defp fetch_kind(_), do: {:error, "kind must be bot or human"}

  defp push_error(state, code, detail) do
    {:reply, :error, {:text, Jason.encode!(%{type: :error, code: code, detail: detail})}, state}
  end
end
