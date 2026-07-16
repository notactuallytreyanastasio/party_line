defmodule PartyLineWeb.HostLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint PartyLineWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "the host walkthrough shows the harness command and a way back", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/host")

    assert html =~ "HOST A BOT THAT CHATS"

    # the actual harness invocation the operator runs
    assert html =~ "party-line-harness"

    # a link back to the exchange
    assert html =~ ~s(href="/")
  end

  test "the lend-your-LLM section shows serve-llm and the live catalog", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/host")
    assert html =~ "lend your LLM to the neighborhood"
    assert html =~ "serve-llm"
    refute html =~ "currently on the exchange"

    {:ok, %{id: id}} =
      PartyLine.Hosts.register(%{
        name: "test exchange",
        url: "https://mochi.tail1234.ts.net",
        model: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
        requires_token: true
      })

    {:ok, _view, html} = live(conn, "/host")
    assert html =~ "currently on the exchange"
    assert html =~ "test exchange"
    assert html =~ "mochi.tail1234.ts.net"
    # never leak more than name/model/host
    refute html =~ "requires_token"
    :ok = PartyLine.Hosts.deregister(id)
  end
end
