defmodule PartyLine.Asks do
  @moduledoc """
  Questions in flight to strangers' laptops.

  The third facet: someone types a question, the router picks a leased agent,
  the agent's own machine answers. This module is the correlator in between —
  it hands the question out, remembers who's waiting, and makes sure every
  question ends *somehow*.

  ## Why this exists at all

  The reply never comes back on the call that sent it. `Bots.request_answer/3`
  drops a message into a WebSocket process and returns; the answer arrives —
  maybe — as a separate `answered` frame, minutes later, from a laptop that may
  by then be in a bag. So something has to hold the thread: ask_id → who asked,
  what we told them, and when to give up.

  ## Every ask terminates

  That's the whole contract. A federated exchange has no failure mode more
  common than "the machine went away", so silence cannot be one of the
  outcomes. Every ask ends in exactly one of:

    * `{:answered, ask_id, body, decision}` — it worked
    * `{:ask_failed, ask_id, :timeout}` — lid closed, model wedged, who knows
    * `{:ask_failed, ask_id, :agent_gone}` — the socket died while we waited
    * `{:ask_failed, ask_id, :nobody_online}` — returned from `ask/3` directly

  The asker is monitored too: nobody holds a slot for a browser tab that's
  already closed.
  """

  use GenServer

  alias PartyLine.Agents.{Card, Router}
  alias PartyLine.Bots

  require Logger

  @name __MODULE__
  # generous: a 20B on a laptop, cold, is slow — and a wrong answer that
  # arrives beats a right one we already gave up on
  @default_timeout 90_000

  defstruct pending: %{}, cursor: 0, bots: Bots, timeout: @default_timeout

  # ── client ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Route `prompt` to an agent and send the answer to `asker` when it lands.

  Returns `{:ok, ask_id, decision}` immediately — the decision is who we picked
  and why, so the UI can say "asking DigimonOtis…" before any tokens exist. Or
  `{:error, :nobody_online}` when the exchange is empty, which is the only
  thing there's nothing honest to do about.
  """
  @spec ask(GenServer.server(), pid(), String.t(), keyword()) ::
          {:ok, String.t(), Router.decision()} | {:error, :nobody_online}
  def ask(server \\ @name, asker, prompt, opts)

  def ask(server, asker, prompt, opts) when is_pid(asker) and is_binary(prompt) do
    GenServer.call(server, {:ask, asker, prompt, opts})
  end

  @doc "A host returned an answer. Called from its socket."
  def deliver(server \\ @name, ask_id, body),
    do: GenServer.cast(server, {:deliver, ask_id, body})

  @doc "How many questions are in flight."
  def in_flight(server \\ @name), do: GenServer.call(server, :in_flight)

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       bots: Keyword.get(opts, :bots, Bots),
       timeout: Keyword.get(opts, :timeout, @default_timeout)
     }}
  end

  @impl true
  def handle_call({:ask, asker, prompt, opts}, _from, state) do
    cards = Bots.cards(state.bots)

    case Router.route(cards, prompt, cursor: state.cursor, target: opts[:target]) do
      {:error, :nobody_online} ->
        {:reply, {:error, :nobody_online}, state}

      {:ok, decision} ->
        ask_id = "ask-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

        :ok =
          Bots.request_answer(state.bots, decision.card.persona, %{id: ask_id, prompt: prompt})

        # Monitor the asker, not the agent: the agent is reachable only through
        # its socket process, which Bots already watches. If the tab closes we
        # drop the slot rather than deliver into the void.
        ref = Process.monitor(asker)
        timer = Process.send_after(self(), {:timeout, ask_id}, state.timeout)

        pending = %{
          asker: asker,
          ref: ref,
          timer: timer,
          decision: decision,
          persona: decision.card.persona
        }

        {:reply, {:ok, ask_id, decision},
         %{state | pending: Map.put(state.pending, ask_id, pending), cursor: decision.cursor}}
    end
  end

  def handle_call(:in_flight, _from, state), do: {:reply, map_size(state.pending), state}

  @impl true
  def handle_cast({:deliver, ask_id, body}, state) do
    case Map.pop(state.pending, ask_id) do
      {nil, _} ->
        # a late answer for something we already timed out, or a host inventing
        # ids. Either way there's nobody to tell.
        {:noreply, state}

      {pending, rest} ->
        finish(pending)
        send(pending.asker, {:answered, ask_id, body, pending.decision})
        {:noreply, %{state | pending: rest}}
    end
  end

  @impl true
  def handle_info({:timeout, ask_id}, state) do
    case Map.pop(state.pending, ask_id) do
      {nil, _} ->
        {:noreply, state}

      {pending, rest} ->
        Process.demonitor(pending.ref, [:flush])

        Logger.info("ask #{ask_id} timed out on #{pending.persona}")
        send(pending.asker, {:ask_failed, ask_id, :timeout})
        {:noreply, %{state | pending: rest}}
    end
  end

  # the asker went away (closed tab); drop the slot, tell nobody
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.pending, fn {_id, p} -> p.ref == ref end) do
      nil ->
        {:noreply, state}

      {ask_id, pending} ->
        Process.cancel_timer(pending.timer)
        {:noreply, %{state | pending: Map.delete(state.pending, ask_id)}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp finish(pending) do
    Process.cancel_timer(pending.timer)
    Process.demonitor(pending.ref, [:flush])
  end

  @doc "The byline for a decision — who answered, on what."
  def byline(%{card: card}), do: Card.byline(card)
end
