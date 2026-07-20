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

  test "a bot may hold the floor briefly, but a run is capped" do
    room = start_room()
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {b, _} = join(room, :b, %{name: "Bo", kind: :bot})

    # Ada takes the floor and keeps developing her thought while Bo stays
    # quiet — continuation is allowed at the dampened fairness
    for n <- 1..3 do
      beat = await_beat(:a)
      Room.bid(room, a, beat, 0.9)
      assert_receive {:a, %{type: :grant, grant_id: grant}}, 1_000
      Room.speak(room, a, grant, "my point, part #{n}")
      assert_receive {:b, %{type: :message}}, 1_000
    end

    # after max_consecutive in a row, Ada is hard-zeroed until someone else talks
    beat = await_beat(:a)
    Room.bid(room, a, beat, 0.95)
    Room.bid(room, b, beat, 0.3)
    assert_receive {:b, %{type: :grant}}, 1_000
    refute_receive {:a, %{type: :grant}}, 20
  end

  test "an eager rival outbids a floor-holder" do
    room = start_room()
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {b, _} = join(room, :b, %{name: "Bo", kind: :bot})

    beat = await_beat(:a)
    Room.bid(room, a, beat, 0.9)
    assert_receive {:a, %{type: :grant, grant_id: grant}}, 1_000
    Room.speak(room, a, grant, "me first")
    assert_receive {:b, %{type: :message}}, 1_000

    # Ada's 0.9 is dampened to 0.9 × 0.35 ≈ 0.32; Bo's honest 0.4 beats it
    beat2 = await_beat(:a)
    Room.bid(room, a, beat2, 0.9)
    Room.bid(room, b, beat2, 0.4)
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

    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    {:ok, welcome} = Room.join(room, %{name: "Late", kind: :human, pid: pid})

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

  test "multi-word lowercase handles round-trip presence, roster, and mentions" do
    room = start_room()
    {h, _} = join(room, :h, %{name: "Bobby", kind: :human})
    {_e, _} = join(room, :e, %{name: "erowid smoothie", kind: :bot})

    # presence carries the multi-word name intact
    assert_receive {:h,
                    %{
                      type: :presence,
                      event: :joined,
                      participant: %{name: "erowid smoothie", kind: :bot}
                    }},
                   1_000

    # a human @-mention of the multi-word handle parses through commit_message
    Room.speak(room, h, nil, "@erowid smoothie what do you think?")

    assert_receive {:e,
                    %{
                      type: :message,
                      body: "@erowid smoothie what do you think?",
                      mentions: [%{name: "erowid smoothie", kind: :bot}]
                    }},
                   1_000

    # a later joiner's welcome roster round-trips the name too
    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    {:ok, welcome} = Room.join(room, %{name: "late caller", kind: :human, pid: pid})
    assert Enum.any?(welcome.roster, &(&1.name == "erowid smoothie" and &1.kind == :bot))
  end

  test "leave/2 broadcasts :left and removes the participant from snapshots" do
    room = start_room()
    {e, _} = join(room, :e, %{name: "erowid smoothie", kind: :bot})
    {_d, _} = join(room, :d, %{name: "horse dentist", kind: :bot})

    Room.leave(room, e)

    assert_receive {:d,
                    %{type: :presence, event: :left, participant: %{name: "erowid smoothie"}}},
                   1_000

    refute Enum.any?(Room.snapshot(room).roster, &(&1.name == "erowid smoothie"))
  end

  test "the last bot leaving via leave/2 idles the director until a bot rejoins" do
    room = start_room()
    {e, _} = join(room, :e, %{name: "erowid smoothie", kind: :bot})
    await_beat(:e)

    Room.leave(room, e)
    assert Room.snapshot(room).phase == :idle
    refute_receive {:e, %{type: :beat}}, 150

    # a fresh bot wakes the director again
    {_d, _} = join(room, :d, %{name: "horse dentist", kind: :bot})
    await_beat(:d)
  end

  test "a grant-holder leaving via leave/2 re-opens bidding for the rest" do
    room = start_room()
    {e, _} = join(room, :e, %{name: "erowid smoothie", kind: :bot})
    {_d, _} = join(room, :d, %{name: "horse dentist", kind: :bot})

    beat = await_beat(:e)
    assert_receive {:d, %{type: :beat, beat_id: ^beat}}, 1_000
    Room.bid(room, e, beat, 0.9)
    assert_receive {:e, %{type: :grant}}, 1_000

    Room.leave(room, e)

    assert_receive {:d,
                    %{type: :presence, event: :left, participant: %{name: "erowid smoothie"}}},
                   1_000

    assert_receive {:d, %{type: :beat, beat_id: new_beat}}, 1_000
    assert new_beat != beat
  end

  test "announce/2 rejects unknown ids and is a quiet no-op for the already-visible" do
    room = start_room()
    {_e, _} = join(room, :e, %{name: "erowid smoothie", kind: :bot})
    {h, _} = join(room, :h, %{name: "Bobby", kind: :human})

    assert {:error, :unknown_participant} = Room.announce(room, "p-999")

    # announcing someone already visible succeeds without a duplicate broadcast
    assert :ok = Room.announce(room, h)
    refute_receive {:e, %{type: :presence, event: :announced}}, 50
  end

  test "an over-eager urge clamps to 1.0 and still wins the beat" do
    room = start_room()
    {e, _} = join(room, :e, %{name: "erowid smoothie", kind: :bot})
    {d, _} = join(room, :d, %{name: "horse dentist", kind: :bot})

    beat = await_beat(:e)
    assert_receive {:d, %{type: :beat, beat_id: ^beat}}, 1_000
    Room.bid(room, e, beat, 5.0)
    Room.bid(room, d, beat, 0.9)

    assert_receive {:e, %{type: :grant}}, 1_000
    refute_receive {:d, %{type: :grant}}, 20
  end

  test "a non-numeric urge clamps to zero and loses to any real bid" do
    room = start_room()
    {e, _} = join(room, :e, %{name: "erowid smoothie", kind: :bot})
    {d, _} = join(room, :d, %{name: "horse dentist", kind: :bot})

    beat = await_beat(:e)
    assert_receive {:d, %{type: :beat, beat_id: ^beat}}, 1_000

    # a misbehaving socket reports its urge as a string — clamp/1 is the
    # room's only defense at the wire boundary
    Room.bid(room, e, beat, "high")
    Room.bid(room, d, beat, 0.4)

    assert_receive {:d, %{type: :grant}}, 1_000
    refute_receive {:e, %{type: :grant}}, 20
  end

  test "a bid against a stale beat id is ignored" do
    room = start_room()
    {e, _} = join(room, :e, %{name: "erowid smoothie", kind: :bot})

    beat = await_beat(:e)
    Room.bid(room, e, "#{beat}-stale", 0.9)

    refute_receive {:e, %{type: :grant}}, 150
  end
end
