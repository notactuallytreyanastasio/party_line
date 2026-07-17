defmodule PartyLine.RoomsTest do
  # dial/ensure_lines read global app env and the shared Registry /
  # DynamicSupervisor, so this module runs alone.
  use ExUnit.Case, async: false

  alias PartyLine.Rooms
  alias PartyLine.Rooms.Room

  setup do
    previous = Application.get_env(:party_line, :lines, [])
    Application.put_env(:party_line, :lines, [])
    on_exit(fn -> Application.put_env(:party_line, :lines, previous) end)
    :ok
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Rooms live in the shared DynamicSupervisor, so every room a test creates
  # is torn down afterward — later tests (and later test files) see a clean
  # switchboard.
  defp stop_on_exit(room_id) do
    on_exit(fn ->
      case Rooms.whereis(room_id) do
        {:ok, pid} -> DynamicSupervisor.terminate_child(PartyLine.Rooms.Supervisor, pid)
        {:error, :not_found} -> :ok
      end
    end)

    room_id
  end

  # A participant that only needs to exist: joined via a sleeping pid that
  # stays alive (linked) for the duration of the test.
  defp join_sleeper(room_id, name, kind, opts \\ []) do
    {:ok, room} = Rooms.whereis(room_id)
    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    attrs = Map.merge(%{name: name, kind: kind, pid: pid}, Map.new(opts))
    {:ok, welcome} = Room.join(room, attrs)
    welcome
  end

  test "dial/1 starts and returns a requested valid room id with a url-safe ticket" do
    room_id = stop_on_exit("my-line-2")

    assert %{room_id: ^room_id, ws_url: "/ws/bot/websocket", ticket: ticket} =
             Rooms.dial(%{"room" => room_id})

    assert {:ok, pid} = Rooms.whereis(room_id)
    assert is_pid(pid)

    # 12 random bytes → 16 url-safe base64 chars, no padding
    assert byte_size(ticket) == 16
    assert {:ok, _} = Base.url_decode64(ticket)
  end

  test "dial/1 falls back to room-default for invalid requested ids" do
    invalid = [
      # uppercase
      "Room-X",
      # leading dash / underscore
      "-oops",
      "_oops",
      # path-ish
      "a/b",
      # empty
      "",
      # over 64 bytes
      String.duplicate("a", 65)
    ]

    for bad <- invalid do
      assert %{room_id: "room-default"} = Rooms.dial(%{"room" => bad})
      assert {:error, :not_found} = Rooms.whereis(bad)
    end
  end

  test "dial/1 with no attrs, or a non-binary room value, returns room-default" do
    assert %{room_id: "room-default"} = Rooms.dial()
    assert %{room_id: "room-default"} = Rooms.dial(%{"room" => 42})
    assert %{room_id: "room-default"} = Rooms.dial(%{"room" => nil})
  end

  test "ensure_lines/0 starts every configured line plus room-default" do
    line_a = stop_on_exit(unique_id("line-a"))
    line_b = stop_on_exit(unique_id("line-b"))

    Application.put_env(:party_line, :lines, [
      {line_a, "the boards but for raccoons"},
      {line_b, "dial tones ranked by vibe"}
    ])

    assert :ok = Rooms.ensure_lines()

    assert {:ok, pid_a} = Rooms.whereis(line_a)
    assert {:ok, _pid_b} = Rooms.whereis(line_b)
    assert {:ok, _default} = Rooms.whereis("room-default")

    assert Room.snapshot(pid_a).topic == "the boards but for raccoons"
  end

  test "ensure_room/2 is idempotent and whereis/1 reports liveness" do
    room_id = stop_on_exit(unique_id("room-idem"))

    assert {:ok, pid} = Rooms.ensure_room(room_id, topic: "one ringy dingy")
    assert {:ok, ^pid} = Rooms.ensure_room(room_id)
    assert {:ok, ^pid} = Rooms.whereis(room_id)
    assert Room.snapshot(pid).topic == "one ringy dingy"

    assert {:error, :not_found} = Rooms.whereis(unique_id("room-ghost"))
  end

  test "switchboard_rooms/0 puts configured lines first in config order, then the rest alphabetically" do
    # config order deliberately reversed from alphabetical order
    line_z = stop_on_exit(unique_id("zz-line"))
    line_a = stop_on_exit(unique_id("aa-line"))
    extra = stop_on_exit(unique_id("mm-extra"))

    Application.put_env(:party_line, :lines, [{line_z, "topic z"}, {line_a, "topic a"}])
    assert :ok = Rooms.ensure_lines()
    assert {:ok, _} = Rooms.ensure_room(extra, topic: "walk-up line")

    ids = Enum.map(Rooms.switchboard_rooms(), & &1.id)

    assert [^line_z, ^line_a | rest] = ids
    assert rest == Enum.sort(rest)
    assert extra in rest
    assert "room-default" in rest
  end

  test "directory/0 lists only bots, deduped by name, sorted case-insensitively" do
    room_one = stop_on_exit(unique_id("dir-one"))
    room_two = stop_on_exit(unique_id("dir-two"))
    assert {:ok, _} = Rooms.ensure_room(room_one, topic: "phone book studies")
    assert {:ok, _} = Rooms.ensure_room(room_two, topic: "phone book studies, again")

    # multi-word lowercase handles are the house style — pin the convention
    join_sleeper(room_one, "erowid smoothie", :bot)
    # same handle on a second line dedupes to one directory entry
    join_sleeper(room_two, "erowid smoothie", :bot)
    join_sleeper(room_one, "horse dentist", :bot)
    join_sleeper(room_one, "Zamboni whisperer", :bot)
    join_sleeper(room_one, "just a caller", :human)

    names = Enum.map(Rooms.directory(), & &1.name)

    assert Enum.count(names, &(&1 == "erowid smoothie")) == 1
    refute "just a caller" in names

    # case-insensitive sort: a raw byte sort would put "Zamboni whisperer" first
    erowid = Enum.find_index(names, &(&1 == "erowid smoothie"))
    horse = Enum.find_index(names, &(&1 == "horse dentist"))
    zamboni = Enum.find_index(names, &(&1 == "Zamboni whisperer"))

    assert erowid < horse
    assert horse < zamboni
  end

  test "list_rooms/0 reports topic plus separate bot/human headcounts" do
    room_id = stop_on_exit(unique_id("count"))
    assert {:ok, _} = Rooms.ensure_room(room_id, topic: "headcount hygiene")

    join_sleeper(room_id, "erowid smoothie", :bot)
    join_sleeper(room_id, "horse dentist", :bot)
    join_sleeper(room_id, "loud caller", :human)
    # lurkers are invisible at the roster level, so they never count
    join_sleeper(room_id, "quiet caller", :human, lurk: true)

    assert %{topic: "headcount hygiene", bots: 2, humans: 1} =
             Enum.find(Rooms.list_rooms(), &(&1.id == room_id))
  end

  describe "stumble/1" do
    test "lands you on a live line, never the one you're already on" do
      here = stop_on_exit(unique_id("room-here"))
      there = stop_on_exit(unique_id("room-there"))

      for id <- [here, there] do
        {:ok, _} = Rooms.ensure_room(id, topic: "t")
        join_sleeper(id, "Horse Dentist", :bot)
        join_sleeper(id, "erowid smoothie", :bot)
        # a line has to have said something to earn a stranger
        {:ok, room} = Rooms.whereis(id)
        %{participant_id: pid} = join_sleeper(id, "Speaker", :human)
        Room.speak(room, pid, nil, "already talking")
        _ = Room.snapshot(room)
      end

      assert {:ok, ^there} = Rooms.stumble(exclude: here)
      assert {:ok, ^here} = Rooms.stumble(exclude: there)
    end

    test "an empty exchange is honest about it rather than dumping you in silence" do
      assert {:error, :nowhere} = Rooms.stumble()
    end

    test "a line with bots but no conversation yet is not a stumble target" do
      quiet = stop_on_exit(unique_id("room-quiet"))
      {:ok, _} = Rooms.ensure_room(quiet, topic: "t")
      join_sleeper(quiet, "Horse Dentist", :bot)

      assert {:error, :nowhere} = Rooms.stumble()
    end

    test "candidates carry what the matchmaker scores on" do
      id = stop_on_exit(unique_id("room-cand"))
      {:ok, _} = Rooms.ensure_room(id, topic: "the topic")
      join_sleeper(id, "Horse Dentist", :bot)
      %{participant_id: pid} = join_sleeper(id, "Bobby", :human)
      {:ok, room} = Rooms.whereis(id)
      Room.speak(room, pid, nil, "hi")
      _ = Room.snapshot(room)

      cand = Enum.find(Rooms.stumble_candidates(), &(&1.id == id))

      assert %{bots: 1, humans: 1, said_anything?: true, topic: "the topic"} = cand
      assert is_integer(cand.silent_beats)
    end
  end
end
