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

  test "the desktop has a taskbar, and Start cascades into the room browser", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    # the desktop is quietly crashing, decoratively
    assert html =~ "General Protection Fault"
    assert html =~ "lose any unsaved gossip"

    # the merger nobody asked for
    assert html =~ "WINDOZE"
    assert html =~ "NEXTELL"
    assert html =~ "merged communications experience"

    # taskbar with Start; menu closed until clicked
    assert html =~ "Start"
    refute html =~ "PartyLine95"

    html = view |> element("button.retro-start-btn") |> render_click()
    assert html =~ "PartyLine95"
    assert html =~ "Chat Rooms"
    assert html =~ "Shut Down"

    # the easter egg: rooms cascade shows live rooms with topic + headcount
    {:ok, _} = PartyLine.Rooms.ensure_room("room-default")
    html = view |> element("button", "Chat Rooms") |> render_click()
    assert html =~ "room-default"
    assert html =~ "tonight:"
    assert html =~ "masquerade line"

    # shut down is a bit, not a feature
    html = view |> element("button", "Shut Down") |> render_click()
    assert html =~ "it is now safe to stay on the line"
  end

  test "statusbar counts cataloged neighborhood LLMs", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ ~r/\d+ neighborhood LLMs? cataloged/

    {:ok, %{id: id}} =
      PartyLine.Hosts.register(%{
        name: "statusbar exchange",
        url: "http://example.ts.net:8377",
        model: "fake",
        requires_token: true
      })

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "1 neighborhood LLM cataloged"
    :ok = PartyLine.Hosts.deregister(id)
  end
end
