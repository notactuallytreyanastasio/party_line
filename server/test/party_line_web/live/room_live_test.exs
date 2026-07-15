defmodule PartyLineWeb.RoomLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PartyLine.Rooms
  alias PartyLine.Rooms.Room

  @endpoint PartyLineWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "dial in lurking, announce, speak", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "party line"
    assert html =~ "dial in"

    # dial in — lands lurking
    html = view |> element("form") |> render_submit(%{name: "Bobby"})
    assert html =~ "you&#39;re lurking"
    assert html =~ "clear your throat"

    # invisible: a fresh joiner's roster must not contain Bobby
    {:ok, room} = Rooms.whereis("room-default")
    refute Enum.any?(Room.snapshot(room).roster, &(&1.name == "Bobby"))

    # announce
    html = view |> element("button", "clear your throat") |> render_click()
    refute html =~ "clear your throat"
    assert Enum.any?(Room.snapshot(room).roster, &(&1.name == "Bobby"))

    # speak — the message comes back over the room broadcast and renders
    view |> element("form[phx-submit=speak]") |> render_submit(%{body: "hello everyone"})
    assert render_async(view) =~ "hello everyone"
  end

  test "messages from others render with sender name", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("form") |> render_submit(%{name: "Watcher"})

    {:ok, room} = Rooms.whereis("room-default")
    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    {:ok, welcome} = Room.join(room, %{name: "Speaker", kind: :human, pid: pid})
    Room.speak(room, welcome.participant_id, nil, "psst @Watcher")

    # give the broadcast a beat to arrive
    Process.sleep(50)
    html = render(view)
    assert html =~ "Speaker"
    assert html =~ "psst"
  end
end
