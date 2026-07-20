defmodule PartyLineWeb.AskLiveTest do
  @moduledoc """
  The /ask LiveView, driven against a fake exchange (a real Asks correlator in
  front of a fake Bots). The synchronous branches (empty roster, empty body,
  nobody-online) render immediately; the answered path uses message-ordering
  barriers instead of sleeping — a sync Asks call flushes the queued deliver
  cast, then render/1 flushes the LiveView's {:answered}.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PartyLine.Asks
  alias PartyLine.Test.ExchangeFake

  @endpoint PartyLineWeb.Endpoint

  setup do
    on_exit(fn ->
      Application.delete_env(:party_line, :api_asks)
      Application.delete_env(:party_line, :api_bots)
    end)

    %{conn: build_conn()}
  end

  defp use_exchange(cards, answer \\ fn _ -> "the couch is structurally sound" end) do
    %{asks: asks, bots: bots} = ExchangeFake.start!(cards, answer)
    Application.put_env(:party_line, :api_asks, asks)
    Application.put_env(:party_line, :api_bots, bots)
    asks
  end

  test "mounts with an empty roster and shows the no-one-home hint", %{conn: conn} do
    use_exchange([])
    {:ok, _view, html} = live(conn, "/ask")
    assert html =~ "start a harness"
    assert html =~ "ask anything"
  end

  test "mounts with a live persona in the roster", %{conn: conn} do
    use_exchange([ExchangeFake.card("Horse Dentist", "gemma-4-e4b-8bit")])
    {:ok, _view, html} = live(conn, "/ask")
    assert html =~ "Horse Dentist"
    assert html =~ "on the exchange"
  end

  test "typing updates the draft (phx-change)", %{conn: conn} do
    use_exchange([])
    {:ok, view, _html} = live(conn, "/ask")
    html = render_change(form(view, "#ask-form"), %{"body" => "why do cats knead"})
    assert html =~ ~s(value="why do cats knead")
  end

  test "an empty ask is a no-op — no turn is added", %{conn: conn} do
    use_exchange([ExchangeFake.card("Horse Dentist")])
    {:ok, view, _html} = live(conn, "/ask")
    html = render_submit(form(view, "#ask-form"), %{"body" => "   "})
    assert html =~ "ask anything"
    assert html =~ "0 turns"
  end

  test "asking with nobody online renders the system apology", %{conn: conn} do
    use_exchange([])
    {:ok, view, _html} = live(conn, "/ask")
    html = render_submit(form(view, "#ask-form"), %{"body" => "anyone home?"})
    assert html =~ "on the exchange right now — no laptops"
  end

  test "a routed ask renders your turn then the agent's answer", %{conn: conn} do
    asks = use_exchange([ExchangeFake.card("Horse Dentist")], fn _ -> "knead = kitten muscle memory" end)
    {:ok, view, _html} = live(conn, "/ask")

    html = render_submit(form(view, "#ask-form"), %{"body" => "why do cats knead"})
    # your turn lands synchronously; the answer is still in flight
    assert html =~ "why do cats knead"

    # barrier 1: a sync Asks call is ordered behind the queued deliver cast, so
    # when it returns the {:answered} message has been sent to the LiveView
    Asks.in_flight(asks)
    # barrier 2: render/1 flushes the LiveView's mailbox before rendering
    answered = render(view)
    assert answered =~ "knead = kitten muscle memory"
    # the input re-enables once the answer lands (waiting cleared)
    refute answered =~ ~s(disabled)
  end
end
