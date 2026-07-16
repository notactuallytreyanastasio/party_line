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
    {:ok, view, html} = live(conn, "/line")
    assert html =~ "party line"
    assert html =~ "dial in"

    # the desktop behind the window is the exchange's phone book
    assert html =~ "PARTY LINE TELEPHONE DIRECTORY"
    assert html =~ "OPERATOR"
    assert html =~ ~r/KL5-\d{4}|KL5-TIME/

    # dial in — lands lurking
    html = view |> element("form") |> render_submit(%{name: "Bobby"})
    assert html =~ "you&#39;re lurking"
    assert html =~ "clear your throat"

    # invisible: a fresh joiner's roster must not contain Bobby
    {:ok, room} = Rooms.whereis("room-default")
    refute Enum.any?(Room.snapshot(room).roster, &(&1.name == "Bobby"))

    # announce — in the room-default window specifically (other lines may exist)
    view
    |> element(~s{[phx-value-room="room-default"]}, "clear your throat")
    |> render_click()

    assert Enum.any?(Room.snapshot(room).roster, &(&1.name == "Bobby"))

    # speak — the message comes back over the room broadcast and renders
    view
    |> element("#speak-form-#{window_index(view, "room-default")}")
    |> render_submit(%{body: "hello everyone"})

    # snapshot serializes behind the speak cast; render behind the broadcast
    _ = Room.snapshot(room)
    assert render(view) =~ "hello everyone"
  end

  test "messages from others render with sender name", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/line")
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

  test "the switchboard opens a window per live line", %{conn: conn} do
    previous = Application.get_env(:party_line, :lines, [])

    Application.put_env(:party_line, :lines, [
      {"room-switch-a", "topic alpha"},
      {"room-switch-b", "topic beta"}
    ])

    on_exit(fn -> Application.put_env(:party_line, :lines, previous) end)

    {:ok, view, _html} = live(conn, "/line")
    html = view |> element("form") |> render_submit(%{name: "Plugger"})

    # one window per room, each with its own titlebar and speak form
    assert html =~ "room-switch-a"
    assert html =~ "topic alpha"
    assert html =~ "room-switch-b"
    assert html =~ "topic beta"
    assert html =~ "speak-form-0"
    assert html =~ "speak-form-1"

    # announcing in ONE window leaves the others lurking
    view
    |> element(~s{[phx-value-room="room-switch-a"]}, "clear your throat")
    |> render_click()

    {:ok, room_a} = Rooms.whereis("room-switch-a")
    {:ok, room_b} = Rooms.whereis("room-switch-b")
    assert Enum.any?(Room.snapshot(room_a).roster, &(&1.name == "Plugger"))
    refute Enum.any?(Room.snapshot(room_b).roster, &(&1.name == "Plugger"))

    # speaking targets only the announced room
    view
    |> element(~s{#speak-form-#{window_index(view, "room-switch-a")}})
    |> render_submit(%{body: "hello line a"})

    Process.sleep(50)
    assert Enum.any?(Room.snapshot(room_a).transcript, &(&1.body == "hello line a"))
    refute Enum.any?(Room.snapshot(room_b).transcript, &(&1.body == "hello line a"))
  end

  # find which window index a room landed in (window order = list_rooms order)
  defp window_index(view, room_id) do
    html = render(view)

    Regex.scan(~r/☎ (room-[a-z0-9-]+)/, html)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
    |> Enum.find_index(&(&1 == room_id))
  end

  test "operator messages render as a host voice, not a speaker line", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/line")
    view |> element("form") |> render_submit(%{name: "Watcher"})

    # feed the LiveView a synthetic operator message directly — no dependency
    # on the core agent's director code; handle_info stream-inserts any :message.
    send(
      view.pid,
      {:party_line,
       %{
         type: :message,
         room_id: "room-default",
         seq: 999,
         message_id: "m-999",
         ts: "1996-01-01T00:00:00Z",
         sender: %{participant_id: "p-op", name: "Operator", kind: :operator},
         body: "that's time on raccoons. new topic: pierogi. @Bo, you start.",
         mentions: []
       }}
    )

    html = render(view)
    # the host's latest line is PINNED in the topicbar, not repeated in the log
    assert html =~ "retro-topicbar"
    assert html =~ "new topic: pierogi"
    refute html =~ "retro-chatline--operator"
    refute html =~ ~r/retro-chatname[^>]*>\s*Operator/

    # a second operator line REPLACES the pinned one
    send(
      view.pid,
      {:party_line,
       %{
         type: :message,
         room_id: "room-default",
         seq: 1000,
         message_id: "m-1000",
         ts: "1996-01-01T00:01:00Z",
         sender: %{participant_id: "p-op", name: "Operator", kind: :operator},
         body: "quiet line. try this: opossums.",
         mentions: []
       }}
    )

    html = render(view)
    assert html =~ "quiet line. try this: opossums."
    refute html =~ "new topic: pierogi"
  end
end
