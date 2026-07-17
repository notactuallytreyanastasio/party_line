defmodule PartyLineWeb.RoomLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PartyLine.Rooms
  alias PartyLine.Rooms.Room

  @endpoint PartyLineWeb.Endpoint

  setup do
    PartyLine.DataCase.checkout_singletons!()
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

    # snapshot serializes behind the speak cast, so the broadcast has already
    # reached the view's mailbox; render then queues behind it
    _ = Room.snapshot(room)
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

    # each snapshot call serializes behind that room's speak cast
    assert Enum.any?(Room.snapshot(room_a).transcript, &(&1.body == "hello line a"))
    refute Enum.any?(Room.snapshot(room_b).transcript, &(&1.body == "hello line a"))
  end

  test "buddy list, clipping to the wall, and DMs", %{conn: conn} do
    {:ok, v1, _} = live(conn, "/line")
    v1 |> element("form") |> render_submit(%{name: "clipper"})

    {:ok, v2, _} = live(Phoenix.ConnTest.build_conn(), "/line")
    v2 |> element("form") |> render_submit(%{name: "receiver"})

    # AIM energy: rooms + online users + your screen name
    html = render(v2)
    assert html =~ "buddy list"
    assert html =~ "clipper"
    assert html =~ "screen name: receiver"

    # someone says something worth keeping (unique per run: the shared in-memory
    # clips wall persists across tests within a run)
    uniq = System.unique_integer([:positive])
    body = "unique-clip-body-#{uniq}"
    note = "lmaoo-#{uniq}"

    {:ok, room} = Rooms.whereis("room-default")
    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    {:ok, w} = Room.join(room, %{name: "Speaker", kind: :human, pid: pid})
    Room.speak(room, w.participant_id, nil, body)

    msg = Enum.find(Room.snapshot(room).transcript, &(&1.body == body))

    # the client hook pushes the selection; then clip it to the wall
    idx = window_index(v2, "room-default")

    v2
    |> element("#messages-#{idx}")
    |> render_hook("select", %{"room" => "room-default", "ids" => [msg.message_id]})

    html = render(v2)
    assert html =~ "1 clipped"
    # share is a typeahead over online users, only offered when others exist
    assert html =~ "share with… (type a name)"
    assert html =~ ~s{<option value="clipper">}

    # sharing to a name that isn't on keeps the selection and says so
    v2 |> element("#clipshare-#{idx}") |> render_submit(%{buddy: "ghost"})
    html = render(v2)
    assert html =~ "nobody by that name is on"
    assert html =~ "1 clipped"

    v2 |> element("#clipbar-#{idx}") |> render_submit(%{note: note})

    clip = Enum.find(PartyLine.Clips.wall(50), &(&1.note == note))
    assert clip.clipped_by == "receiver"
    assert [%{body: ^body, sender_name: "Speaker"}] = clip.messages
    # selection cleared after clipping
    refute render(v2) =~ "1 clipped"

    # DM: receiver IMs clipper; clipper's switchboard auto-opens the window
    v2 |> element(~s{button[phx-value-buddy="clipper"]}, "IM") |> render_click()

    v2
    |> element(~s{form[phx-submit="dm_send"]})
    |> render_submit(%{buddy: "clipper", body: "did you see that"})

    # send_dm is a call that broadcasts before replying, so by the time the
    # submit returns the DM is already in v1's mailbox — render queues behind it
    html1 = render(v1)
    assert html1 =~ "✉ receiver"
    assert html1 =~ "did you see that"

    # the landing wall shows it, and laughing counts
    {:ok, landing, lhtml} = live(Phoenix.ConnTest.build_conn(), "/")
    assert lhtml =~ "FROM THE WALL"
    assert lhtml =~ body

    landing |> element(~s{button[phx-value-id="#{clip.id}"]}) |> render_click()
    assert %{laughs: 1} = Enum.find(PartyLine.Clips.wall(50), &(&1.id == clip.id))
  end

  test "dialing with a blank name shows an error and stays on the dialing stage", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/line")

    html = view |> element("form") |> render_submit(%{name: "   "})
    assert html =~ "pick a name first"
    # still on the dialing stage, not the switchboard
    assert html =~ "dial in"
    assert html =~ "party line — dialing"
  end

  test "a participant leaving prunes the window roster", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/line")
    view |> element("form") |> render_submit(%{name: "roster watcher"})

    {:ok, room} = Rooms.whereis("room-default")
    base = on_the_line(view, "room-default")

    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    {:ok, welcome} = Room.join(room, %{name: "brief visitor", kind: :human, pid: pid})

    # join is a call that broadcasts presence before replying, so the view has
    # already been told; on_the_line renders, which queues behind that message
    assert on_the_line(view, "room-default") == base + 1

    Room.leave(room, welcome.participant_id)

    # leave is a cast — snapshot to serialize behind it before re-rendering
    _ = Room.snapshot(room)
    assert on_the_line(view, "room-default") == base
  end

  # Regression: send_dm's 4-arity once bound the sender's name as the GenServer
  # server (double-default ambiguity) and clip sharing crashed the LiveView.
  test "sharing a clip DMs the buddy and clears the selection", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    body = "share-worthy-#{uniq}"

    # the recipient dials first so the sharer's buddy list includes them
    {:ok, catcher, _} = live(conn, "/line")
    catcher |> element("form") |> render_submit(%{name: "clip catcher"})

    {:ok, sharer, _} = live(Phoenix.ConnTest.build_conn(), "/line")
    sharer |> element("form") |> render_submit(%{name: "clip sharer"})

    {:ok, room} = Rooms.whereis("room-default")
    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    {:ok, welcome} = Room.join(room, %{name: "clip source #{uniq}", kind: :human, pid: pid})
    Room.speak(room, welcome.participant_id, nil, body)
    msg = Enum.find(Room.snapshot(room).transcript, &(&1.body == body))

    idx = window_index(sharer, "room-default")

    sharer
    |> element("#messages-#{idx}")
    |> render_hook("select", %{"room" => "room-default", "ids" => [msg.message_id]})

    assert render(sharer) =~ "1 clipped"

    sharer |> element("#clipshare-#{idx}") |> render_submit(%{buddy: "clip catcher"})

    # success clears the selection (the failure path keeps it)
    refute render(sharer) =~ "1 clipped"

    # the recipient's switchboard auto-opens the DM with the quoted clip —
    # send_dm broadcast before replying, so this render is already ordered
    html = render(catcher)
    assert html =~ "✉ clip sharer"
    assert html =~ "clipped from room-default"
    assert html =~ body
  end

  test "closing a DM window removes it", %{conn: conn} do
    {:ok, target, _} = live(conn, "/line")
    target |> element("form") |> render_submit(%{name: "dm target"})

    {:ok, opener, _} = live(Phoenix.ConnTest.build_conn(), "/line")
    opener |> element("form") |> render_submit(%{name: "dm opener"})

    opener |> element(~s{button[phx-value-buddy="dm target"]}, "IM") |> render_click()
    assert render(opener) =~ "✉ dm target"

    opener
    |> element(~s{button[phx-click="close_dm"][phx-value-buddy="dm target"]})
    |> render_click()

    refute render(opener) =~ "✉ dm target"
  end

  test "speaking while lurking is a no-op", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    body = "lurker noise #{uniq}"

    {:ok, view, _html} = live(conn, "/line")
    view |> element("form") |> render_submit(%{name: "quiet possum"})

    # no announce — submit the speak form straight from the lurking state
    view
    |> element("#speak-form-#{window_index(view, "room-default")}")
    |> render_submit(%{body: body})

    # snapshot serializes behind the speak cast: if the lurker's line were
    # going to commit, it would have by the time this call returns
    {:ok, room} = Rooms.whereis("room-default")
    refute Enum.any?(Room.snapshot(room).transcript, &(&1.body == body))
  end

  # the "N on the line" count in a window's statusbar
  defp on_the_line(view, room_id) do
    [_, n] = Regex.run(~r/#{room_id}[^<]*<\/span>\s*<span>(\d+) on the line/, render(view))
    String.to_integer(n)
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
