defmodule PartyLine.Clips do
  @moduledoc """
  The wall: quotes and exchanges humans clipped from the bots because they
  were funny (or otherwise worth keeping).

  **Postgres is the source of truth; ETS is the read cache.** Clipping and
  laughing persist to the Repo and then update the cache; the wall reads from
  the cache, warmed from Postgres on boot. The captured transcript is a list
  of typed `PartyLine.Clips.Message` embeds. The landing page ranks by laughs,
  then recency.
  """
  use GenServer

  alias PartyLine.Clips.Clip
  alias PartyLine.Repo

  require Logger

  @name __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Save a clip. `messages` is a list of `%{sender_name, kind, body, ts}` in
  conversation order; `attrs` needs :room_id and :clipped_by and may carry
  :topic and :note. Returns `{:ok, clip}` or `{:error, changeset}`.
  """
  def clip(server \\ @name, messages, attrs) do
    GenServer.call(server, {:clip, messages, attrs})
  end

  def laugh(server \\ @name, id), do: GenServer.call(server, {:laugh, id})

  @doc "One clip by id, or nil."
  def get(server \\ @name, id), do: GenServer.call(server, {:get, id})

  @doc "Test/dev only: drop the cache so a fresh (sandboxed) DB shows through."
  def reset(server \\ @name), do: GenServer.call(server, :reset)

  @doc "All clips, best first: laughs desc, then newest."
  def wall(server \\ @name, limit \\ 20)

  def wall(limit, 20) when is_integer(limit), do: GenServer.call(@name, {:wall, limit})
  def wall(server, limit), do: GenServer.call(server, {:wall, limit})

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{clips: :ets.new(:clips, [:set, :protected, read_concurrency: true])},
     {:continue, :warm}}
  end

  @impl true
  def handle_continue(:warm, s), do: {:noreply, warm(s, 5)}

  @impl true
  def handle_info({:warm, attempts}, s), do: {:noreply, warm(s, attempts)}

  # warm from Postgres; retry with backoff (bounded) on a boot-time DB blip
  defp warm(s, attempts) do
    Enum.each(Repo.all(Clip), &:ets.insert(s.clips, {&1.id, &1}))
    s
  rescue
    e ->
      if attempts > 0 do
        Logger.warning("clips cache warm failed, retrying: #{Exception.message(e)}")
        Process.send_after(self(), {:warm, attempts - 1}, 3_000)
      else
        Logger.error("clips cache warm gave up: #{Exception.message(e)}")
      end

      s
  end

  @impl true
  def handle_call({:clip, messages, attrs}, _from, s) do
    row =
      attrs
      |> Map.take([:room_id, :topic, :clipped_by, :note])
      |> Map.put(:id, gen_id())
      |> Map.put(:messages, messages)

    case %Clip{} |> Clip.changeset(row) |> Repo.insert() do
      {:ok, clip} ->
        :ets.insert(s.clips, {clip.id, clip})
        {:reply, {:ok, clip}, s}

      {:error, changeset} ->
        {:reply, {:error, changeset}, s}
    end
  end

  def handle_call({:laugh, id}, _from, s) do
    case lookup(s, id) do
      nil ->
        {:reply, {:error, :not_found}, s}

      clip ->
        {:ok, clip} =
          clip
          |> Ecto.Changeset.change(laughs: clip.laughs + 1)
          |> Repo.update()

        :ets.insert(s.clips, {clip.id, clip})
        {:reply, {:ok, clip.laughs}, s}
    end
  end

  def handle_call({:get, id}, _from, s), do: {:reply, lookup(s, id), s}

  def handle_call(:reset, _from, s) do
    :ets.delete_all_objects(s.clips)
    {:reply, :ok, s}
  end

  def handle_call({:wall, limit}, _from, s) do
    clips =
      s.clips
      |> :ets.select([{{:_, :"$1"}, [], [:"$1"]}])
      |> Enum.sort(&hotter?/2)
      |> Enum.take(limit)

    {:reply, clips, s}
  end

  # best first: more laughs wins; newer breaks the tie (DateTime term order
  # isn't chronological, so compare it explicitly rather than via sort_by)
  defp hotter?(%Clip{laughs: same} = a, %Clip{laughs: same} = b),
    do: DateTime.compare(a.inserted_at, b.inserted_at) != :lt

  defp hotter?(%Clip{laughs: la}, %Clip{laughs: lb}), do: la > lb

  defp lookup(s, id) do
    case :ets.lookup(s.clips, id) do
      [{^id, clip}] -> clip
      [] -> nil
    end
  end

  defp gen_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
