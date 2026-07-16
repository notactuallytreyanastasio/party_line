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
    {:ok, %{room: nil, room_id: nil, participant_id: nil}}
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
      state = %{state | room: room, room_id: room_id, participant_id: welcome.participant_id}
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
