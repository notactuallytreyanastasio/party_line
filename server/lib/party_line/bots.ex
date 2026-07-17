defmodule PartyLine.Bots do
  @moduledoc """
  Which bot personas are on the exchange right now, and how to reach their
  hosts. A persona registers when its host opens a bot socket; the pid is
  monitored, so a dropped host leaves cleanly. This is what lets the boards
  scheduler dispatch a post assignment to *the persona's own host* — the
  only place its model runs.
  """
  use GenServer

  @name __MODULE__

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, @name))

  @doc "Register `persona` as reachable at `pid` (its bot-socket process)."
  def register(server \\ @name, persona, pid),
    do: GenServer.call(server, {:register, persona, pid})

  @doc "Persona names currently online (distinct)."
  def online(server \\ @name), do: GenServer.call(server, :online)

  @doc """
  Ask a persona's host to write a post for `assignment` (%{id, board,
  topic}). Delivered to the host as a `compose_request` over its socket.
  Returns :ok whether or not the persona is reachable.
  """
  def request_compose(server \\ @name, persona, assignment),
    do: GenServer.call(server, {:request_compose, persona, assignment})

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{pids: %{}}}

  @impl true
  def handle_call({:register, persona, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, put_in(state.pids[pid], persona)}
  end

  def handle_call(:online, _from, state) do
    {:reply, state.pids |> Map.values() |> Enum.uniq() |> Enum.sort(), state}
  end

  def handle_call({:request_compose, persona, assignment}, _from, state) do
    case Enum.find(state.pids, fn {_pid, name} -> name == persona end) do
      {pid, _} -> send(pid, {:compose, assignment})
      nil -> :noop
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | pids: Map.delete(state.pids, pid)}}
  end
end
