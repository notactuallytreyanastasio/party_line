defmodule PartyLine.Rooms.RoomTest do
  use ExUnit.Case, async: true

  alias PartyLine.Rooms.{Config, Room}

  # Millisecond-scale director so every scenario runs in real time.
  @fast Config.new(
          cooldown_min: 10,
          cooldown_max: 20,
          reading_ms_per_char: 0,
          bid_window: 60,
          fast_bid_window: 50,
          grant_deadline: 120,
          preempt_cooldown: 10,
          silence_backoff: [30, 40, 50, 60],
          urge_threshold: 0.2,
          max_strikes: 3,
          strike_penalty: 60_000
        )

  defp start_room(ctx_or_opts \\ []) do
    opts = if is_list(ctx_or_opts), do: ctx_or_opts, else: []

    start_supervised!(
      {Room, Keyword.merge([id: "room-test", topic: "test topic", config: @fast], opts)}
    )
  end

  # Each participant is a relay process so events arrive tagged by identity.
  defp join(room, tag, attrs) do
    test = self()

    pid =
      spawn_link(fn ->
        Stream.repeatedly(fn ->
          receive do
            {:party_line, event} -> send(test, {tag, event})
          end
        end)
        |> Stream.run()
      end)

    {:ok, welcome} = Room.join(room, Map.put(attrs, :pid, pid))
    {welcome.participant_id, pid}
  end

  defp await_beat(tag) do
    assert_receive {^tag, %{type: :beat, beat_id: beat_id}}, 1_000
    beat_id
  end

  test "highest scored bid wins the grant and the message broadcasts" do
    room = start_room()
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {b, _} = join(room, :b, %{name: "Bo", kind: :bot})

    beat = await_beat(:a)
    assert_receive {:b, %{type: :beat, beat_id: ^beat}}, 1_000

    Room.bid(room, a, beat, 0.9)
    Room.bid(room, b, beat, 0.4)

    assert_receive {:a, %{type: :grant, grant_id: grant, context_seq: 0}}, 1_000
    refute_receive {:b, %{type: :grant}}, 20

    Room.speak(room, a, grant, "opening the topic")

    assert_receive {:a, %{type: :message, seq: 1, sender: %{name: "Ada"}}}, 1_000
    assert_receive {:b, %{type: :message, seq: 1, body: "opening the topic"}}, 1_000
  end

  test "beats keep coming in silence, and bids below threshold never win" do
    room = start_room()
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})

    beat1 = await_beat(:a)
    Room.bid(room, a, beat1, 0.05)
    refute_receive {:a, %{type: :grant}}, 150

    # the room stays alive: another beat arrives after the backoff
    beat2 = await_beat(:a)
    assert beat2 != beat1
  end

  test "a bot cannot follow up its own message" do
    room = start_room()
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {b, _} = join(room, :b, %{name: "Bo", kind: :bot})

    beat = await_beat(:a)
    Room.bid(room, a, beat, 0.9)
    assert_receive {:a, %{type: :grant, grant_id: grant}}, 1_000
    Room.speak(room, a, grant, "me first")
    assert_receive {:b, %{type: :message}}, 1_000

    beat2 = await_beat(:a)
    Room.bid(room, a, beat2, 0.95)
    Room.bid(room, b, beat2, 0.3)

    # fairness hard-zeroes Ada's bid: Bo wins despite the lower urge
    assert_receive {:b, %{type: :grant}}, 1_000
    refute_receive {:a, %{type: :grant}}, 20
  end

  test "grant timeout revokes, strikes, and re-opens bidding; late speak is rejected" do
    room = start_room()
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})

    beat = await_beat(:a)
    Room.bid(room, a, beat, 0.9)
    assert_receive {:a, %{type: :grant, grant_id: grant}}, 1_000

    # don't speak: deadline passes
    assert_receive {:a, %{type: :grant_revoked, grant_id: ^grant, reason: :timeout}}, 1_000

    # bidding re-opened immediately
    assert_receive {:a, %{type: :beat}}, 1_000

    # the tardy speak against the dead grant is dropped, not double-spoken
    Room.speak(room, a, grant, "too late", "ref-1")
    assert_receive {:a, %{type: :speak_rejected, grant_id: ^grant, client_ref: "ref-1"}}, 1_000
    refute_receive {:a, %{type: :message, body: "too late"}}, 100
  end

  test "three strikes quarantines a bot from grants" do
    room = start_room()
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})

    for _ <- 1..3 do
      beat = await_beat(:a)
      Room.bid(room, a, beat, 0.9)
      assert_receive {:a, %{type: :grant}}, 1_000
      assert_receive {:a, %{type: :grant_revoked, reason: :timeout}}, 1_000
    end

    beat = await_beat(:a)
    Room.bid(room, a, beat, 0.9)
    refute_receive {:a, %{type: :grant}}, 150
  end

  test "human speak broadcasts immediately, preempts a live grant, and triggers a fast beat" do
    room = start_room()
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {h, _} = join(room, :h, %{name: "Bobby", kind: :human})

    beat = await_beat(:a)
    Room.bid(room, a, beat, 0.9)
    assert_receive {:a, %{type: :grant, grant_id: grant}}, 1_000

    # human barges in while Ada holds the floor
    Room.speak(room, h, nil, "@Ada what do you think?")

    assert_receive {:a, %{type: :grant_revoked, grant_id: ^grant, reason: :preempted}}, 1_000

    assert_receive {:a, %{type: :message, sender: %{kind: :human}, mentions: [%{name: "Ada"}]}},
                   1_000

    assert_receive {:h, %{type: :message, body: "@Ada what do you think?"}}, 1_000

    # a fresh (fast) beat follows so Ada can answer with current context
    assert_receive {:a, %{type: :beat}}, 1_000
  end

  test "humans never receive beats and cannot bid" do
    room = start_room()
    {_a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {h, _} = join(room, :h, %{name: "Bobby", kind: :human})

    beat = await_beat(:a)
    refute_receive {:h, %{type: :beat}}, 20

    Room.bid(room, h, beat, 0.99)
    refute_receive {:h, %{type: :grant}}, 150
  end

  test "lurkers are invisible until they announce" do
    room = start_room()
    {_a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {h, _} = join(room, :h, %{name: "Bobby", kind: :human, lurk: true})

    # no presence for the lurker
    refute_receive {:a, %{type: :presence, participant: %{name: "Bobby"}}}, 50

    # invisible in a fresh joiner's roster
    {_b, _} = join(room, :b, %{name: "Bo", kind: :bot})
    snapshot = Room.snapshot(room)
    refute Enum.any?(snapshot.roster, &(&1.name == "Bobby"))

    :ok = Room.announce(room, h)

    assert_receive {:a, %{type: :presence, event: :announced, participant: %{name: "Bobby"}}},
                   1_000

    assert Enum.any?(Room.snapshot(room).roster, &(&1.name == "Bobby"))
  end

  test "welcome carries topic, roster, and transcript tail" do
    room = start_room()
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})

    beat = await_beat(:a)
    Room.bid(room, a, beat, 0.9)
    assert_receive {:a, %{type: :grant, grant_id: grant}}, 1_000
    Room.speak(room, a, grant, "hello room")
    assert_receive {:a, %{type: :message, seq: 1}}, 1_000

    test = self()
    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    {:ok, welcome} = Room.join(room, %{name: "Late", kind: :human, pid: pid})
    send(test, :ok)

    assert welcome.room.topic == "test topic"
    assert [%{body: "hello room", seq: 1}] = welcome.transcript
    assert Enum.any?(welcome.roster, &(&1.name == "Ada"))
  end

  test "grant holder disconnecting re-opens bidding" do
    room = start_room()
    {a, apid} = join(room, :a, %{name: "Ada", kind: :bot})
    {b, _} = join(room, :b, %{name: "Bo", kind: :bot})

    beat = await_beat(:a)
    assert_receive {:b, %{type: :beat, beat_id: ^beat}}, 1_000
    Room.bid(room, a, beat, 0.9)
    assert_receive {:a, %{type: :grant}}, 1_000

    Process.unlink(apid)
    Process.exit(apid, :kill)

    # Bo learns Ada left and bidding re-opens
    assert_receive {:b, %{type: :presence, event: :left, participant: %{name: "Ada"}}}, 1_000
    assert_receive {:b, %{type: :beat, beat_id: new_beat}}, 1_000
    assert new_beat != beat
    _ = b
  end
end
