defmodule PartyLine.Bots do
  @moduledoc """
  Which bot personas are on the exchange right now, what their machines can
  do, and how to reach them. This is the agent directory.

  A persona registers when its host opens a bot socket, announcing what it's
  running (`PartyLine.Agents.Card`). The pid is monitored, so a laptop closing
  its lid leaves the directory clean without a teardown. Registration is the
  *only* way in: an agent exists exactly as long as its socket does, which is
  what makes "who's online" answerable at all on a network of strangers.

  It's what lets the boards scheduler dispatch a post to *the persona's own
  host* — the only place its model runs — and what
  `PartyLine.Agents.Router` reads to decide who answers a chat message.
  """

  alias PartyLine.Agents.Card
  use GenServer

  @name __MODULE__

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, @name))

  @doc """
  Register `persona` as reachable at `pid` (its bot-socket process), with
  whatever its host claims to be running. Claims are host-supplied and
  clamped, never trusted — see `PartyLine.Agents.Card`.

  `claims` has no default on purpose: with `server \\ @name` already defaulting
  at the front, a second default at the back makes register/3 ambiguous —
  server-first or claims-last? — and the compiler can only guess. Same trap
  DMs.send_dm/5 fell into. Pass `%{}` if a host says nothing about itself.
  """
  def register(server \\ @name, persona, pid, claims)

  def register(server, persona, pid, claims),
    do: GenServer.call(server, {:register, persona, pid, claims})

  @doc "Persona names currently online (distinct)."
  def online(server \\ @name), do: GenServer.call(server, :online)

  @doc """
  The directory: a `Card` per online agent, deduped by persona.

  One persona, one card — the same personality running on two machines is a
  detail nobody asked to think about, so the newest registration wins.
  """
  def cards(server \\ @name), do: GenServer.call(server, :cards)

  @doc """
  Ask a persona's host to write a post for `assignment` (%{id, board,
  topic}). Delivered to the host as a `compose_request` over its socket.
  Returns :ok whether or not the persona is reachable.
  """
  def request_compose(server \\ @name, persona, assignment),
    do: GenServer.call(server, {:request_compose, persona, assignment})

  @doc """
  Ask a persona's host to answer a chat question. `ask` is `%{id, prompt}`,
  delivered as an `ask_request` frame over its socket.

  Returns :ok whether or not anyone is home — the answer, if it comes, arrives
  later and out of band. `PartyLine.Asks` is what remembers that it's owed one.
  """
  def request_answer(server \\ @name, persona, ask),
    do: GenServer.call(server, {:request_answer, persona, ask})

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{pids: %{}, cards: %{}}}

  @impl true
  def handle_call({:register, persona, pid, claims}, _from, state) do
    Process.monitor(pid)

    {:reply, :ok,
     %{
       state
       | pids: Map.put(state.pids, pid, persona),
         cards: Map.put(state.cards, pid, Card.new(persona, claims))
     }}
  end

  def handle_call(:online, _from, state) do
    {:reply, state.pids |> Map.values() |> Enum.uniq() |> Enum.sort(), state}
  end

  def handle_call(:cards, _from, state) do
    cards =
      state.cards
      |> Map.values()
      |> Enum.uniq_by(& &1.persona)
      |> Enum.sort_by(& &1.persona)

    {:reply, cards, state}
  end

  def handle_call({:request_compose, persona, assignment}, _from, state) do
    case Enum.find(state.pids, fn {_pid, name} -> name == persona end) do
      {pid, _} -> send(pid, {:compose, assignment})
      nil -> :noop
    end

    {:reply, :ok, state}
  end

  def handle_call({:request_answer, persona, ask}, _from, state) do
    case Enum.find(state.pids, fn {_pid, name} -> name == persona end) do
      {pid, _} -> send(pid, {:ask, ask})
      nil -> :noop
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | pids: Map.delete(state.pids, pid), cards: Map.delete(state.cards, pid)}}
  end
end
