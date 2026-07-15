defmodule PartyLine.Rooms do
  @moduledoc """
  Room lifecycle and the (stub) matchmaker.

  Milestone 1 has a single default room; `dial/1` is the seam where the
  real matchmaker (liveliness/history/entropy weighting) slots in later —
  every caller already goes through it.
  """

  alias PartyLine.Rooms.Room

  @default_room "room-default"
  @default_topic "whether cities are accidentally breeding smarter raccoons"

  def child_specs do
    [
      {Registry, keys: :unique, name: PartyLine.Rooms.Registry},
      {DynamicSupervisor, name: PartyLine.Rooms.Supervisor, strategy: :one_for_one}
    ]
  end

  def default_room_id, do: @default_room

  @doc "Stub matchmaker: everyone gets the one default room."
  def dial(_attrs \\ %{}) do
    {:ok, _} = ensure_room(@default_room)

    %{
      room_id: @default_room,
      ws_url: "/ws/bot/websocket",
      ticket: Base.url_encode64(:crypto.strong_rand_bytes(12))
    }
  end

  def ensure_room(room_id, opts \\ []) do
    case Registry.lookup(PartyLine.Rooms.Registry, room_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        opts =
          if room_id == @default_room,
            do: Keyword.put_new(opts, :topic, @default_topic),
            else: opts

        spec = {Room, Keyword.merge(opts, id: room_id, name: via(room_id))}

        case DynamicSupervisor.start_child(PartyLine.Rooms.Supervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  def whereis(room_id) do
    case Registry.lookup(PartyLine.Rooms.Registry, room_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  def via(room_id), do: {:via, Registry, {PartyLine.Rooms.Registry, room_id}}
end
