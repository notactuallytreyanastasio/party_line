defmodule PartyLineWeb.StumbleLiveTest do
  @moduledoc """
  /stumble is RoomLive in its other mode: one matchmade line instead of the
  switchboard's four. These drive the real LiveView against real rooms.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PartyLine.Rooms
  alias PartyLine.Rooms.Room

  @endpoint PartyLineWeb.Endpoint

  setup do
    previous = Application.get_env(:party_line, :lines, [])
    Application.put_env(:party_line, :lines, [])
    on_exit(fn -> Application.put_env(:party_line, :lines, previous) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # A line worth stumbling into: bots on it, and already talking.
  defp live_line(id) do
    {:ok, _} = Rooms.ensure_room(id, topic: "topic for #{id}")

    on_exit(fn ->
      case Rooms.whereis(id) do
        {:ok, pid} -> DynamicSupervisor.terminate_child(PartyLine.Rooms.Supervisor, pid)
        {:error, :not_found} -> :ok
      end
    end)

    {:ok, room} = Rooms.whereis(id)

    for name <- ["Horse Dentist", "erowid smoothie"] do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      {:ok, _} = Room.join(room, %{name: name, kind: :bot, pid: pid})
    end

    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    {:ok, w} = Room.join(room, %{name: "Speaker-#{id}", kind: :human, pid: pid})
    Room.speak(room, w.participant_id, nil, "already underway in #{id}")
    _ = Room.snapshot(room)
    id
  end

  test "you land on exactly one line, mid-conversation", %{conn: conn} do
    a = live_line("room-stumble-a-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/stumble")
    html = view |> element("form") |> render_submit(%{name: "wanderer"})

    # one window, not the switchboard's four
    assert html =~ "already underway in #{a}"
    assert html =~ "↻ stumble again"
    refute has_element?(view, "#pane-1"), "a stumble is one line, not a control room"
  end

  test "stumbling again moves you to a different line", %{conn: conn} do
    a = live_line("room-stumble-a-#{System.unique_integer([:positive])}")
    b = live_line("room-stumble-b-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/stumble")
    view |> element("form") |> render_submit(%{name: "wanderer"})

    first = if render(view) =~ a, do: a, else: b
    other = if first == a, do: b, else: a

    html = view |> element(~s{button[phx-click="stumble_again"]}) |> render_click()

    assert html =~ "already underway in #{other}",
           "the re-roll must not land you back where you already were"
  end

  test "you actually leave the line you stumbled off, not just exclude it", %{conn: conn} do
    a = live_line("room-stumble-a-#{System.unique_integer([:positive])}")
    b = live_line("room-stumble-b-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/stumble")
    view |> element("form") |> render_submit(%{name: "wanderer"})

    left = if render(view) =~ "topic for #{a}", do: a, else: b

    # Announce first: a lurker is invisible in the roster by design, so only
    # someone who has cleared their throat leaves a trace to check for. Without
    # this the assertion below passes whether or not we ever leave.
    view
    |> element(~s{[phx-value-room="#{left}"]}, "clear your throat")
    |> render_click()

    {:ok, room} = Rooms.whereis(left)
    assert Enum.any?(Room.snapshot(room).roster, &(&1.name == "wanderer"))

    view |> element(~s{button[phx-click="stumble_again"]}) |> render_click()

    _ = Room.snapshot(room)

    refute Enum.any?(Room.snapshot(room).roster, &(&1.name == "wanderer")),
           "stumbling on must hang up the old line, not just avoid redialing it"
  end

  test "an empty exchange says so instead of pretending", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/stumble")
    html = view |> element("form") |> render_submit(%{name: "wanderer"})

    assert html =~ "every line is quiet right now"
    refute html =~ "stumble again"
  end

  test "/line is still the switchboard, patched into every line", %{conn: conn} do
    live_line("room-sw-a-#{System.unique_integer([:positive])}")
    live_line("room-sw-b-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/line")
    view |> element("form") |> render_submit(%{name: "operator"})

    assert has_element?(view, "#pane-0")
    assert has_element?(view, "#pane-1"), "the switchboard shows every line at once"
    refute has_element?(view, ~s{button[phx-click="stumble_again"]})
  end

  test "the only live line keeps you on it rather than stranding you", %{conn: conn} do
    # Regression: the re-roll used to hang up first and pick second. With one
    # live line that left you staring at a room you'd already walked out of,
    # and the error had nowhere to render. Found by clicking it, not by a test.
    only = live_line("room-only-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/stumble")
    view |> element("form") |> render_submit(%{name: "wanderer"})
    assert render(view) =~ "topic for #{only}"

    html = view |> element(~s{button[phx-click="stumble_again"]}) |> render_click()

    assert html =~ "nowhere else to stumble"
    assert html =~ "topic for #{only}", "you keep the line you're on"

    # and you're still really on it: announcing still lands in the roster
    view
    |> element(~s{[phx-value-room="#{only}"]}, "clear your throat")
    |> render_click()

    {:ok, room} = Rooms.whereis(only)

    assert Enum.any?(Room.snapshot(room).roster, &(&1.name == "wanderer")),
           "a failed re-roll must not have hung up the line"
  end
end
