defmodule PartyLine.Clips do
  @moduledoc """
  The wall: quotes and exchanges humans clipped from the bots because they
  were funny (or otherwise worth keeping). Persisted in DETS — durable
  across restarts, zero new dependencies. The landing page ranks by
  laughs, then recency.
  """

  use GenServer

  @name __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Save a clip. `messages` is a list of `%{sender_name, kind, body, ts}` in
  conversation order; `attrs` needs :room_id, :topic, :clipped_by and may
  carry :note.
  """
  def clip(server \\ @name, messages, attrs) do
    GenServer.call(server, {:clip, messages, attrs})
  end

  def laugh(server \\ @name, id), do: GenServer.call(server, {:laugh, id})

  @doc "All clips, best first: laughs desc, then newest."
  def wall(server \\ @name, limit \\ 20)

  def wall(limit, 20) when is_integer(limit), do: GenServer.call(@name, {:wall, limit})
  def wall(server, limit), do: GenServer.call(server, {:wall, limit})

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path =
      Keyword.get_lazy(opts, :path, fn ->
        Application.get_env(:party_line, :clips_path) ||
          Path.expand("~/.party_line/clips.dets")
      end)

    File.mkdir_p!(Path.dirname(path))
    table = Keyword.get(opts, :table, :"party_line_clips_#{System.unique_integer([:positive])}")
    {:ok, dets} = :dets.open_file(table, file: String.to_charlist(path), type: :set)
    {:ok, %{dets: dets}}
  end

  @impl true
  def handle_call({:clip, messages, attrs}, _from, state) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    clip = %{
      id: id,
      messages: messages,
      room_id: Map.fetch!(attrs, :room_id),
      topic: Map.get(attrs, :topic),
      clipped_by: Map.fetch!(attrs, :clipped_by),
      note: Map.get(attrs, :note),
      laughs: 0,
      inserted_at: DateTime.to_iso8601(DateTime.utc_now())
    }

    :ok = :dets.insert(state.dets, {id, clip})
    {:reply, {:ok, clip}, state}
  end

  def handle_call({:laugh, id}, _from, state) do
    case :dets.lookup(state.dets, id) do
      [{^id, clip}] ->
        clip = %{clip | laughs: clip.laughs + 1}
        :ok = :dets.insert(state.dets, {id, clip})
        {:reply, {:ok, clip.laughs}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:wall, limit}, _from, state) do
    clips =
      :dets.foldl(fn {_id, clip}, acc -> [clip | acc] end, [], state.dets)
      |> Enum.sort_by(&{&1.laughs, &1.inserted_at}, :desc)
      |> Enum.take(limit)

    {:reply, clips, state}
  end

  @impl true
  def terminate(_reason, state), do: :dets.close(state.dets)
end
