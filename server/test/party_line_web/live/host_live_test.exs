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
end
