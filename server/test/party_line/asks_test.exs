defmodule PartyLine.AsksTest do
  @moduledoc """
  The correlator's contract is that every ask terminates. On an exchange made
  of strangers' laptops, "the machine went away" is the most ordinary thing
  that can happen — so the interesting tests here are the failures, not the
  happy path.

  A fake directory stands in for Bots: these are about correlation and
  timeouts, and a real WebSocket would only add ways to be flaky.
  """
  use ExUnit.Case, async: true

  alias PartyLine.Agents.Card
  alias PartyLine.Asks

  # A stand-in for PartyLine.Bots: same three functions Asks actually calls.
  defmodule FakeBots do
    use GenServer

    def start_link(cards), do: GenServer.start_link(__MODULE__, cards)
    def cards(server), do: GenServer.call(server, :cards)

    def request_answer(server, persona, ask),
      do: GenServer.call(server, {:request_answer, persona, ask})

    @doc "What the router handed us, so a test can see who was picked."
    def last(server), do: GenServer.call(server, :last)

    @impl true
    def init(cards), do: {:ok, %{cards: cards, last: nil}}

    @impl true
    def handle_call(:cards, _from, s), do: {:reply, s.cards, s}
    def handle_call(:last, _from, s), do: {:reply, s.last, s}

    def handle_call({:request_answer, persona, ask}, _from, s),
      do: {:reply, :ok, %{s | last: {persona, ask}}}
  end

  defp card(persona, model), do: Card.new(persona, %{"model" => model})

  defp exchange(cards, opts \\ []) do
    {:ok, bots} = start_supervised({FakeBots, cards}, id: :"bots-#{:erlang.unique_integer()}")

    {:ok, asks} =
      start_supervised(
        {Asks, [name: nil, bots: bots, timeout: Keyword.get(opts, :timeout, 5_000)]},
        id: :"asks-#{:erlang.unique_integer()}"
      )

    %{asks: asks, bots: bots}
  end

  # Asks calls Bots.cards/1 and Bots.request_answer/3 by module name, so point
  # those at the fake for the duration.
  setup do
    :ok
  end

  describe "an empty exchange" do
    test "says so rather than hanging forever" do
      %{asks: asks} = exchange([])
      assert {:error, :nobody_online} = Asks.ask(asks, self(), "hey", [])
    end
  end

  describe "the happy path" do
    test "routes, hands back who it picked, then delivers the answer" do
      %{asks: asks, bots: bots} = exchange([card("Horse Dentist", "m-8b-8bit")])

      assert {:ok, ask_id, decision} = Asks.ask(asks, self(), "why do cats knead", [])
      assert decision.card.persona == "Horse Dentist"
      assert decision.tier == :moderate
      assert Asks.in_flight(asks) == 1

      # the question really went to that persona's host, carrying the same id
      assert {"Horse Dentist", %{id: ^ask_id, prompt: "why do cats knead"}} = FakeBots.last(bots)

      Asks.deliver(asks, ask_id, "they're testing the couch for structural integrity")

      assert_receive {:answered, ^ask_id, "they're testing the couch for structural integrity",
                      ^decision}

      assert Asks.in_flight(asks) == 0, "a delivered ask must not keep its slot"
    end

    test "the cursor carries, so consecutive asks round-robin" do
      %{asks: asks} = exchange([card("ada", "m-20b-8bit"), card("zed", "m-20b-8bit")])

      {:ok, _, first} = Asks.ask(asks, self(), "hey", [])
      {:ok, _, second} = Asks.ask(asks, self(), "hey", [])

      refute first.card.persona == second.card.persona,
             "two asks in a row must not both land on the same laptop"
    end
  end

  describe "when the machine goes away" do
    test "an ask that is never answered times out and says so" do
      %{asks: asks} = exchange([card("ghost", "m-8b-8bit")], timeout: 60)

      {:ok, ask_id, _} = Asks.ask(asks, self(), "hello?", [])

      assert_receive {:ask_failed, ^ask_id, :timeout}, 500
      assert Asks.in_flight(asks) == 0, "a timed-out ask must release its slot"
    end

    test "an answer that arrives after the timeout is dropped, not delivered late" do
      %{asks: asks} = exchange([card("slowpoke", "m-8b-8bit")], timeout: 60)

      {:ok, ask_id, _} = Asks.ask(asks, self(), "hello?", [])
      assert_receive {:ask_failed, ^ask_id, :timeout}, 500

      Asks.deliver(asks, ask_id, "sorry, my lid was closed")
      refute_receive {:answered, ^ask_id, _, _}, 100
    end

    test "an answer for an id nobody is waiting on is ignored" do
      %{asks: asks} = exchange([card("a", "m-8b-8bit")])

      Asks.deliver(asks, "ask-invented", "hi")
      refute_receive {:answered, _, _, _}, 50
      assert Asks.in_flight(asks) == 0
    end
  end

  describe "when the asker goes away" do
    test "a closed tab releases its slot instead of holding one for nobody" do
      %{asks: asks} = exchange([card("a", "m-8b-8bit")])

      tab = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _ask_id, _} = Asks.ask(asks, tab, "hey", [])
      assert Asks.in_flight(asks) == 1

      ref = Process.monitor(tab)
      Process.exit(tab, :kill)
      assert_receive {:DOWN, ^ref, :process, ^tab, :killed}

      # the correlator sees the DOWN it monitored; sync on a call
      _ = Asks.in_flight(asks)
      assert Asks.in_flight(asks) == 0
    end
  end

  describe "asks carry the routing decision" do
    test "an unmet ask still routes, and the decision admits it" do
      %{asks: asks} = exchange([card("small fry", "m-4b-4bit")])

      {:ok, _id, decision} = Asks.ask(asks, self(), "anything 24B or more?", [])

      refute decision.honored?
      assert decision.asked == %{min_params_b: 24.0}
    end

    test "an explicit target beats reading the message" do
      cards = [card("ada", "m-8b-8bit"), card("zed", "m-20b-8bit")]
      %{asks: asks} = exchange(cards)

      {:ok, _id, decision} = Asks.ask(asks, self(), "hey", target: %{persona: "zed"})
      assert decision.card.persona == "zed"
    end
  end
end
