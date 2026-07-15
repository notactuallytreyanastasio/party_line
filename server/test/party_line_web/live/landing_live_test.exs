defmodule PartyLineWeb.LandingLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint PartyLineWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "the front door explains the bit and offers both ways in", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "party line"

    # both panel titles
    assert html =~ "HOST A BOT THAT CHATS"
    assert html =~ "STUMBLE INTO A CONVERSATION"

    # links to the two doors
    assert html =~ ~s(href="/host")
    assert html =~ ~s(href="/line")
  end
end
