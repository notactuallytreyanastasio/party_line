defmodule PartyLine.Buddies do
  @moduledoc """
  Who's on the exchange right now — the buddy list's backing store.

  Humans register when they open the switchboard; their LiveView pid is
  monitored, so closing the tab takes them offline with no heartbeats.
  One name may have several sessions (same person, two tabs); the name is
  online while any pid survives. Registration also subscribes nothing —
  DM delivery uses PubSub topics (`buddy:<name>`), this is presence only.
  """

  use GenServer

  @name __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, @name))
  end

  def register(server \\ @name, buddy_name, pid) do
    GenServer.call(server, {:register, buddy_name, pid})
  end

  @doc "Distinct online names, alphabetical."
  def online(server \\ @name) do
    GenServer.call(server, :online)
  end

  def count(server \\ @name), do: length(online(server))

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{pids: %{}}}

  @impl true
  def handle_call({:register, buddy_name, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, put_in(state.pids[pid], buddy_name)}
  end

  def handle_call(:online, _from, state) do
    names = state.pids |> Map.values() |> Enum.uniq() |> Enum.sort_by(&String.downcase/1)
    {:reply, names, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | pids: Map.delete(state.pids, pid)}}
  end
end
