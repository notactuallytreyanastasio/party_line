defmodule PartyLine.Test.ExchangeFake do
  @moduledoc """
  A model-free stand-in for the federated exchange, for testing the completion
  API end to end without a laptop on the other end.

  It plays the `Bots` role (`cards/1`, `request_answer/3`) in front of a real
  `PartyLine.Asks` correlator: when a question is handed out it answers it
  immediately by calling `Asks.deliver/3`, so the whole real path —
  routing, correlation, delivery — runs, only the model is canned.
  """
  use GenServer

  alias PartyLine.Agents.Card
  alias PartyLine.Asks

  defstruct cards: [], answer: nil, asks: nil, last: nil

  @doc """
  Start a fake exchange: a fake Bots plus a real Asks wired to it.

  `cards` is the online roster (`[Card.t()]`); `answer` is a `fn prompt ->
  body end`. Returns `%{bots: pid, asks: pid}` — point the API at them with
  `config :party_line, :api_asks` / `:api_bots`.
  """
  def start!(cards, answer \\ fn _ -> "the couch is structurally sound" end) do
    {:ok, bots} = GenServer.start_link(__MODULE__, %{cards: cards, answer: answer})
    {:ok, asks} = Asks.start_link(name: nil, bots: bots)
    :ok = GenServer.call(bots, {:set_asks, asks})
    %{bots: bots, asks: asks}
  end

  @doc "Convenience for a one-persona roster."
  def card(persona, model \\ "m-8b-8bit", claims \\ %{}) do
    Card.new(persona, Map.merge(%{"model" => model}, claims))
  end

  # ── the Bots interface Asks calls ──────────────────────────────────────────

  def cards(server), do: GenServer.call(server, :cards)

  def request_answer(server, persona, ask),
    do: GenServer.call(server, {:request_answer, persona, ask})

  def last(server), do: GenServer.call(server, :last)

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(attrs), do: {:ok, struct!(__MODULE__, attrs)}

  @impl true
  def handle_call(:cards, _from, s), do: {:reply, s.cards, s}

  def handle_call({:set_asks, asks}, _from, s), do: {:reply, :ok, %{s | asks: asks}}

  def handle_call(:last, _from, s), do: {:reply, s.last, s}

  def handle_call({:request_answer, persona, %{id: id, prompt: prompt}}, _from, s) do
    # deliver is a cast, so it queues on Asks behind the in-flight ask handler
    # and lands after the pending slot is registered — the real ordering.
    Asks.deliver(s.asks, id, s.answer.(prompt))
    {:reply, :ok, %{s | last: {persona, prompt}}}
  end
end
