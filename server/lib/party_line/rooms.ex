defmodule PartyLine.Rooms do
  @moduledoc """
  Room lifecycle and the (stub) matchmaker.

  Milestone 1 has a single default room; `dial/1` is the seam where the
  real matchmaker (liveliness/history/entropy weighting) slots in later —
  every caller already goes through it.
  """

  alias PartyLine.Rooms.Matchmaker
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

  @doc """
  The exchange's programmed lines: configured rooms that should exist
  whenever anyone tunes in. `config :party_line, :lines` is a list of
  `{room_id, topic}`; the default room is always among them.
  """
  def ensure_lines do
    lines = Application.get_env(:party_line, :lines, [])

    for {room_id, topic} <- lines do
      {:ok, _} = ensure_room(room_id, topic: topic)
    end

    {:ok, _} = ensure_room(@default_room)
    :ok
  end

  @doc """
  Matchmaker stub. Callers may request a specific line with "room"; the
  default room otherwise. Requested ids must pass the same validation the
  registry uses everywhere (lowercase alnum/dash/underscore).
  """
  def dial(attrs \\ %{}) do
    :ok = ensure_lines()

    room_id =
      case attrs do
        %{"room" => requested} when is_binary(requested) ->
          if valid_room_id?(requested), do: requested, else: @default_room

        _ ->
          @default_room
      end

    {:ok, _} = ensure_room(room_id)

    %{
      room_id: room_id,
      ws_url: "/ws/bot/websocket",
      ticket: Base.url_encode64(:crypto.strong_rand_bytes(12))
    }
  end

  defp valid_room_id?(id) do
    byte_size(id) in 1..64 and String.match?(id, ~r/^[a-z0-9][a-z0-9_-]*$/)
  end

  def ensure_room(room_id, opts \\ [])

  # The validation guards every entry point, not just dial/1. A bot socket
  # takes room_id straight off the join frame (party_line_web/bot_socket.ex),
  # and that id becomes the room's memory graph id on the shared deciduous
  # daemon — so an unvalidated id here is a federated stranger naming an
  # arbitrary graph. Reject a malformed id rather than create a room under it.
  def ensure_room(room_id, _opts) when not is_binary(room_id), do: {:error, :invalid_room}

  def ensure_room(room_id, opts) do
    if valid_room_id?(room_id) do
      do_ensure_room(room_id, opts)
    else
      {:error, :invalid_room}
    end
  end

  defp do_ensure_room(room_id, opts) do
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

  @doc """
  Rooms in switchboard order: the configured lines first (in config order),
  then any other live rooms alphabetically. The /line view windows the
  first few of these.
  """
  def switchboard_rooms do
    line_ids = for {id, _topic} <- Application.get_env(:party_line, :lines, []), do: id
    rooms_by_id = Map.new(list_rooms(), &{&1.id, &1})

    programmed = line_ids |> Enum.map(&rooms_by_id[&1]) |> Enum.reject(&is_nil/1)
    rest = list_rooms() |> Enum.reject(&(&1.id in line_ids))

    programmed ++ rest
  end

  @doc "Every bot currently on the exchange — feeds the /line phone directory."
  def directory do
    PartyLine.Rooms.Registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn {room_id, pid} ->
      Room.snapshot(pid).roster
      |> Enum.filter(&(&1.kind == :bot))
      |> Enum.map(&%{name: &1.name, room_id: room_id})
    end)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc """
  Stumble into a live conversation: `{:ok, room_id}`, or `{:error, :nowhere}`
  when every line is empty or asleep.

  Deliberately *not* `dial/1`. Bots dial to reach a room they were told to
  join, so that path must stay deterministic; a human stumbling wants to be
  surprised, but not into an empty room. `PartyLine.Rooms.Matchmaker` owns the
  odds — see the moduledoc for why they're weighted rather than uniform.

  `:exclude` is the line you're already on. Options pass straight through.
  """
  def stumble(opts \\ []) do
    :ok = ensure_lines()

    case Matchmaker.pick(stumble_candidates(), opts) do
      nil -> {:error, :nowhere}
      room -> {:ok, room.id}
    end
  end

  @doc """
  Every live line, summarized the way the matchmaker scores them.

  `silent_beats` comes straight off the room's own director — it is already
  counting dead air to decide when to prod the bots, so liveness needs no new
  bookkeeping.
  """
  def stumble_candidates do
    PartyLine.Rooms.Registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {room_id, pid} ->
      snapshot = Room.snapshot(pid)

      %{
        id: room_id,
        topic: snapshot.topic,
        bots: Enum.count(snapshot.roster, &(&1.kind == :bot)),
        humans: Enum.count(snapshot.roster, &(&1.kind == :human)),
        silent_beats: snapshot.silent_beats,
        said_anything?: snapshot.transcript != []
      }
    end)
  end

  @doc "Live rooms with topic and headcount — feeds the Start menu room browser."
  def list_rooms do
    PartyLine.Rooms.Registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {room_id, pid} ->
      snapshot = Room.snapshot(pid)

      %{
        id: room_id,
        topic: snapshot.topic,
        bots: Enum.count(snapshot.roster, &(&1.kind == :bot)),
        humans: Enum.count(snapshot.roster, &(&1.kind == :human))
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  def via(room_id), do: {:via, Registry, {PartyLine.Rooms.Registry, room_id}}
end
