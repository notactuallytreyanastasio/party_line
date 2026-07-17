defmodule PartyLine.Rooms.OperatorTest do
  use ExUnit.Case, async: true

  alias PartyLine.Rooms.{Config, Operator, Room}

  @cfg Config.new()

  # ── Pure policy suite ─────────────────────────────────────────────────────
  #
  # Every trigger is decidable from a plain view map, so the whole table can be
  # exercised without a GenServer. `view/1` supplies inert defaults (no trigger
  # firing) that each test perturbs.

  defp view(overrides) do
    base = %{
      now_ms: 1_000_000,
      cur_seq: 100,
      topic: "raccoons and the ethics of the unlatched bin",
      segment: %{
        topic: "raccoons and the ethics of the unlatched bin",
        started_at_ms: 1_000_000,
        messages: 3
      },
      recent: [],
      bots: [],
      silent_beats: 0,
      last_operator_ms: nil,
      spoke_at: %{},
      summoned_at: %{},
      joined_at: %{},
      topic_deck: @cfg.topic_deck,
      suggestions: [],
      ack_topic: nil,
      greet: nil
    }

    Map.merge(base, Map.new(overrides))
  end

  defp loop_recent(loop_window) do
    for i <- 1..loop_window do
      sender = if rem(i, 2) == 0, do: "p-1", else: "p-2"
      %{sender_id: sender, kind: :bot, body: "line #{i}", seq: i}
    end
  end

  test "quiet by default" do
    assert Operator.evaluate(view([]), @cfg) == :quiet
  end

  test "loop_breaker pulls in a third bot when two are stuck in a rally" do
    v =
      view(
        recent: loop_recent(@cfg.loop_window),
        bots: [%{id: "p-1", name: "Ada"}, %{id: "p-2", name: "Bo"}, %{id: "p-3", name: "Cy"}]
      )

    assert {:speak, body} = Operator.evaluate(v, @cfg)
    assert body == "you two have been at it a while. @Cy, weigh in or we change the subject."
  end

  test "loop_breaker with no third bot stays quiet — a duo alternating is just conversation" do
    v =
      view(
        recent: loop_recent(@cfg.loop_window),
        bots: [%{id: "p-1", name: "Ada"}, %{id: "p-2", name: "Bo"}],
        spoke_at: %{"p-1" => 100, "p-2" => 100}
      )

    assert Operator.evaluate(v, @cfg) == :quiet
  end

  test "loop_breaker needs a full window of exactly-two alternating senders" do
    bots = [%{id: "p-1", name: "Ada"}, %{id: "p-2", name: "Bo"}, %{id: "p-3", name: "Cy"}]
    # keep every bot recently-heard so wallflower can't stand in for loop_breaker
    fresh = %{"p-1" => 100, "p-2" => 100, "p-3" => 100}

    # not enough messages
    short = view(recent: loop_recent(@cfg.loop_window - 1), bots: bots, spoke_at: fresh)
    assert Operator.evaluate(short, @cfg) == :quiet

    # three senders, not two
    three =
      loop_recent(@cfg.loop_window)
      |> List.replace_at(0, %{sender_id: "p-3", kind: :bot, body: "x", seq: 0})

    assert Operator.evaluate(view(recent: three, bots: bots, spoke_at: fresh), @cfg) == :quiet
  end

  test "stale_rotation fires when the segment hits its message cap" do
    v =
      view(
        segment: %{topic: "t", started_at_ms: 1_000_000, messages: @cfg.segment_max_messages},
        bots: [%{id: "p-1", name: "Ada"}]
      )

    assert {:speak_and_rotate, _body, new_topic} = Operator.evaluate(v, @cfg)
    assert new_topic in @cfg.topic_deck
  end

  test "stale_rotation fires when the segment ages out" do
    old = %{topic: "t", started_at_ms: 0, messages: 2}
    v = view(segment: old, now_ms: @cfg.segment_max_ms + 1, bots: [%{id: "p-1", name: "Ada"}])

    assert {:speak_and_rotate, _b, _t} = Operator.evaluate(v, @cfg)
  end

  test "stale_rotation fires on a repetitive segment of at least six messages" do
    bodies = [
      "the never-ending dance of urban evolution continues with raccoons",
      "raccoons continue the never-ending dance of urban evolution",
      "truly a never-ending dance of urban evolution here",
      "the never-ending dance of urban evolution never ends",
      "honestly the never-ending dance of urban evolution is eternal",
      "such a never-ending dance of urban evolution we witness"
    ]

    # three distinct senders so loop_breaker stays out of it
    recent =
      bodies
      |> Enum.with_index()
      |> Enum.map(fn {b, i} -> %{sender_id: "p-#{rem(i, 3)}", kind: :bot, body: b, seq: i} end)

    v =
      view(
        recent: recent,
        segment: %{topic: "t", started_at_ms: 1_000_000, messages: 6},
        bots: [%{id: "p-0", name: "Ada"}]
      )

    assert {:speak_and_rotate, _b, _t} = Operator.evaluate(v, @cfg)
  end

  test "a repetitive but under-six segment does not rotate on staleness" do
    v =
      view(
        segment: %{topic: "t", started_at_ms: 1_000_000, messages: 5},
        recent:
          List.duplicate(%{sender_id: "p-0", kind: :bot, body: "same phrase again", seq: 1}, 5)
      )

    assert Operator.evaluate(v, @cfg) == :quiet
  end

  test "wallflower coaxes the quietest long-silent bot" do
    v =
      view(
        cur_seq: 100,
        bots: [%{id: "p-1", name: "Ada"}, %{id: "p-2", name: "Bo"}],
        spoke_at: %{"p-1" => 99, "p-2" => 100 - @cfg.wallflower_after - 5}
      )

    assert {:speak, "@Bo, you've been quiet. thoughts?"} = Operator.evaluate(v, @cfg)
  end

  test "wallflower keeps a per-bot cooldown so it does not nag" do
    v =
      view(
        cur_seq: 100,
        bots: [%{id: "p-2", name: "Bo"}],
        spoke_at: %{"p-2" => 100 - @cfg.wallflower_after - 5},
        summoned_at: %{"p-2" => 100 - 2}
      )

    assert Operator.evaluate(v, @cfg) == :quiet
  end

  test "dead_air tosses a deck prompt without rotating" do
    v = view(silent_beats: @cfg.dead_air_beats)

    assert {:speak, body} = Operator.evaluate(v, @cfg)
    assert String.starts_with?(body, "quiet line. try this: ")
  end

  test "greeting welcomes a human without @-mentioning anyone" do
    assert {:speak, "Bobby just picked up. someone say hi."} =
             Operator.evaluate(view(greet: %{name: "Bobby"}), @cfg)
  end

  test "acking a topic suggestion outranks everything else" do
    v =
      view(
        ack_topic: "the migratory habits of shopping carts",
        greet: %{name: "Bobby"},
        segment: %{topic: "t", started_at_ms: 0, messages: @cfg.segment_max_messages},
        bots: [%{id: "p-1", name: "Ada"}]
      )

    assert {:speak, "noted. it goes in the deck."} = Operator.evaluate(v, @cfg)
  end

  test "priority: loop_breaker outranks a simultaneously-expired segment" do
    v =
      view(
        recent: loop_recent(@cfg.loop_window),
        bots: [%{id: "p-1", name: "Ada"}, %{id: "p-2", name: "Bo"}, %{id: "p-3", name: "Cy"}],
        segment: %{topic: "t", started_at_ms: 0, messages: @cfg.segment_max_messages}
      )

    assert {:speak, "you two have been at it a while." <> _} = Operator.evaluate(v, @cfg)
  end

  test "priority: stale_rotation outranks a waiting wallflower" do
    v =
      view(
        segment: %{topic: "t", started_at_ms: 1_000_000, messages: @cfg.segment_max_messages},
        bots: [%{id: "p-2", name: "Bo"}],
        spoke_at: %{"p-2" => 100 - @cfg.wallflower_after - 5}
      )

    assert {:speak_and_rotate, _b, _t} = Operator.evaluate(v, @cfg)
  end

  test "the operator stays quiet inside its cooldown window" do
    firing = view(greet: %{name: "Bobby"})

    just_spoke = %{firing | last_operator_ms: firing.now_ms - (@cfg.operator_cooldown_ms - 1)}
    assert Operator.evaluate(just_spoke, @cfg) == :quiet

    long_ago = %{firing | last_operator_ms: firing.now_ms - (@cfg.operator_cooldown_ms + 1)}
    assert {:speak, _} = Operator.evaluate(long_ago, @cfg)
  end

  test "rotation cycles to the next deck topic, never the current one" do
    current = Enum.at(@cfg.topic_deck, 0)

    v =
      view(
        topic: current,
        segment: %{
          topic: current,
          started_at_ms: 1_000_000,
          messages: @cfg.segment_max_messages
        },
        bots: [%{id: "p-1", name: "Ada"}, %{id: "p-2", name: "Bo"}],
        spoke_at: %{"p-1" => 100, "p-2" => 100}
      )

    assert {:speak_and_rotate, _b, new_topic} = Operator.evaluate(v, @cfg)
    assert new_topic == Enum.at(@cfg.topic_deck, 1)
  end

  test "an expired segment with no bots present stays quiet" do
    v =
      view(
        segment: %{topic: "t", started_at_ms: 0, messages: @cfg.segment_max_messages},
        bots: []
      )

    assert Operator.evaluate(v, @cfg) == :quiet
  end

  test "rotation from a custom (non-deck) topic picks the first deck entry" do
    v =
      view(
        topic: "our own weird line topic",
        segment: %{
          topic: "our own weird line topic",
          started_at_ms: 1_000_000,
          messages: @cfg.segment_max_messages
        },
        bots: [%{id: "p-1", name: "horse dentist"}]
      )

    assert {:speak_and_rotate, body, new_topic} = Operator.evaluate(v, @cfg)
    assert new_topic == hd(@cfg.topic_deck)
    refute new_topic == "our own weird line topic"
    assert body =~ "@horse dentist, you start."
  end

  test "a single-entry pool equal to the current topic falls back without crashing" do
    v =
      view(
        topic: "the only topic there is",
        topic_deck: ["the only topic there is"],
        segment: %{
          topic: "the only topic there is",
          started_at_ms: 1_000_000,
          messages: @cfg.segment_max_messages
        },
        bots: [%{id: "p-1", name: "horse dentist"}]
      )

    assert {:speak_and_rotate, _body, "the only topic there is"} = Operator.evaluate(v, @cfg)
  end

  test "dead_air's suggested prompt is never the current topic" do
    # the default view's topic IS deck[0], so the prompt must be deck[1]
    v = view(silent_beats: @cfg.dead_air_beats)

    assert {:speak, "quiet line. try this: " <> suggested} = Operator.evaluate(v, @cfg)
    refute suggested == v.topic
    assert suggested == Enum.at(@cfg.topic_deck, 1)
  end

  # ── Room integration suite ─────────────────────────────────────────────────
  #
  # Millisecond-scale director with the operator switched on. Each participant
  # is a relay process so events arrive tagged by identity (the room_test
  # pattern). Beats are broadcast to every bot, so before acting we drain a
  # relay's mailbox to the freshest beat.

  @base [
    operator_enabled: true,
    cooldown_min: 20,
    cooldown_max: 30,
    reading_ms_per_char: 0,
    bid_window: 60,
    fast_bid_window: 50,
    grant_deadline: 300,
    preempt_cooldown: 15,
    silence_backoff: [30, 30, 30, 30],
    urge_threshold: 0.2,
    max_strikes: 3,
    strike_penalty: 60_000,
    operator_cooldown_ms: 10,
    segment_tick_ms: 20,
    segment_max_messages: 50,
    segment_max_ms: 60_000,
    loop_window: 6,
    wallflower_after: 50,
    dead_air_beats: 50,
    stale_threshold: 0.35
  ]

  defp start_room(overrides) do
    config = Config.new(Keyword.merge(@base, overrides))
    start_supervised!({Room, id: "op-room", topic: "test topic", config: config})
  end

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

  # In silence, beats churn; older copies linger in a relay's mailbox. Discard
  # them and block for the next freshly-opened beat so a bid lands in-window.
  defp fresh_beat(tag) do
    flush_beats(tag)
    assert_receive {^tag, %{type: :beat, beat_id: id}}, 1_000
    id
  end

  defp flush_beats(tag) do
    receive do
      {^tag, %{type: :beat}} -> flush_beats(tag)
    after
      0 -> :ok
    end
  end

  # Drive one real grant→speak for `pid_id`, acting on a fresh beat.
  defp say(room, tag, pid_id, body) do
    beat = fresh_beat(tag)
    Room.bid(room, pid_id, beat, 0.9)
    assert_receive {^tag, %{type: :grant, grant_id: g}}, 1_000
    Room.speak(room, pid_id, g, body)
    assert_receive {^tag, %{type: :message, body: ^body}}, 1_000
  end

  test "two bots ping-ponging via real grants get a third pulled in" do
    room = start_room(loop_window: 4)
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {b, _} = join(room, :b, %{name: "Bo", kind: :bot})
    {_c, _} = join(room, :c, %{name: "Cy", kind: :bot})

    say(room, :a, a, "one")
    say(room, :b, b, "two")
    say(room, :a, a, "three")
    say(room, :b, b, "four")

    assert_receive {:c,
                    %{type: :message, sender: %{kind: :operator}, mentions: [%{name: "Cy"}]} = msg},
                   1_000

    assert msg.body =~ "weigh in or we change the subject"
  end

  test "the operator's summons wins the next beat through the director" do
    # The enforcement lever end to end: two bots rally via real grants, the
    # operator @-summons a third, and that third bot's 0.95 bid beats the two
    # loopers' 0.05 gag bids on the very next beat — the director grants the
    # floor to whoever the host called on.
    room = start_room(loop_window: 4)
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {b, _} = join(room, :b, %{name: "Bo", kind: :bot})
    {c, _} = join(room, :c, %{name: "Cy", kind: :bot})

    say(room, :a, a, "@Bo one")
    say(room, :b, b, "@Ada two")
    say(room, :a, a, "@Bo three")
    say(room, :b, b, "@Ada four")

    # loop_breaker fires and hands the floor to the third bot by name
    assert_receive {:c, %{type: :message, sender: %{kind: :operator}, mentions: [%{name: "Cy"}]}},
                   1_000

    # next contested beat: the summoned bot bids 0.95, the loopers bid a 0.05
    # gag. Same beat for all three (one broadcast), so reuse Cy's beat id.
    beat = fresh_beat(:c)
    Room.bid(room, c, beat, 0.95)
    Room.bid(room, a, beat, 0.05)
    Room.bid(room, b, beat, 0.05)

    # the director grants Cy — and only Cy — the floor
    assert_receive {:c, %{type: :grant, grant_id: g}}, 1_000
    refute_received {:a, %{type: :grant}}
    refute_received {:b, %{type: :grant}}

    Room.speak(room, c, g, "fine — here's my take")

    assert_receive {:c, %{type: :message, sender: %{name: "Cy"}, body: "fine — here's my take"}},
                   1_000
  end

  test "a message-count segment rotation announces a new topic that new joiners see" do
    room = start_room(segment_max_messages: 3)
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {b, _} = join(room, :b, %{name: "Bo", kind: :bot})

    say(room, :a, a, "one")
    say(room, :b, b, "two")
    say(room, :a, a, "three")

    assert_receive {:b, %{type: :message, sender: %{kind: :operator}, body: body}}, 1_000
    assert body =~ ~s(that's time on "test topic". new topic:)

    # a fresh joiner's welcome reflects the rotated topic
    test = self()
    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    {:ok, welcome} = Room.join(room, %{name: "Late", kind: :human, pid: pid})
    send(test, :ok)

    refute welcome.room.topic == "test topic"
    assert welcome.room.topic in Config.new(@base).topic_deck
  end

  test "greeting fires when a lurker announces" do
    room = start_room(dead_air_beats: 50)
    {_a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {h, _} = join(room, :h, %{name: "Bobby", kind: :human, lurk: true})

    :ok = Room.announce(room, h)

    assert_receive {:a,
                    %{
                      type: :message,
                      sender: %{kind: :operator},
                      body: "Bobby just picked up. someone say hi.",
                      mentions: []
                    }},
                   1_000
  end

  test "dead air draws a deck prompt after enough silent beats" do
    room = start_room(dead_air_beats: 2)
    {_a, _} = join(room, :a, %{name: "Ada", kind: :bot})

    assert_receive {:a, %{type: :message, sender: %{kind: :operator}, body: body}}, 1_000
    assert String.starts_with?(body, "quiet line. try this: ")
  end

  test "with the operator off (the default) there is zero operator traffic" do
    room = start_room(operator_enabled: false)
    {a, _} = join(room, :a, %{name: "Ada", kind: :bot})
    {b, _} = join(room, :b, %{name: "Bo", kind: :bot})

    refute Enum.any?(Room.snapshot(room).roster, &(&1.name == "Operator"))

    say(room, :a, a, "one")
    say(room, :b, b, "two")

    refute_receive {_, %{type: :message, sender: %{kind: :operator}}}, 200
  end

  # ── Suggestion capture ("@Operator topic: …") through the Room ───────────

  test "a human @Operator topic: suggestion commits normally and draws the ack" do
    room = start_room(operator_cooldown_ms: 0)
    # lurker: no greet message to race the ack
    {h, _} = join(room, :h, %{name: "Bobby", kind: :human, lurk: true})

    Room.speak(room, h, nil, "@Operator topic: the migratory habits of shopping carts")

    assert_receive {:h,
                    %{
                      type: :message,
                      sender: %{kind: :human},
                      body: "@Operator topic: the migratory habits of shopping carts"
                    }},
                   1_000

    assert_receive {:h,
                    %{
                      type: :message,
                      sender: %{kind: :operator},
                      body: "noted. it goes in the deck."
                    }},
                   1_000
  end

  test "suggestion capture is case-insensitive and whitespace-tolerant, but demands text" do
    room = start_room(operator_cooldown_ms: 0)
    {h, _} = join(room, :h, %{name: "Bobby", kind: :human, lurk: true})

    # not a suggestion: no colon after "topic"
    Room.speak(room, h, nil, "@Operator topics are cool")
    assert_receive {:h, %{type: :message, sender: %{kind: :human}}}, 1_000
    refute_receive {:h, %{type: :message, sender: %{kind: :operator}}}, 100

    # not a suggestion: colon but no text
    Room.speak(room, h, nil, "@Operator topic:")
    assert_receive {:h, %{type: :message, sender: %{kind: :human}}}, 1_000
    refute_receive {:h, %{type: :message, sender: %{kind: :operator}}}, 100

    # shouty and sloppy still lands
    Room.speak(room, h, nil, "  @OPERATOR   topic:   the great glitter embargo  ")

    assert_receive {:h,
                    %{
                      type: :message,
                      sender: %{kind: :operator},
                      body: "noted. it goes in the deck."
                    }},
                   1_000
  end

  test "a captured suggestion becomes the next rotation target" do
    suggestion = "the migratory habits of shopping carts #{System.unique_integer([:positive])}"
    room = start_room(segment_max_messages: 3, operator_cooldown_ms: 0)
    {a, _} = join(room, :a, %{name: "horse dentist", kind: :bot})
    {h, _} = join(room, :h, %{name: "Bobby", kind: :human, lurk: true})

    # the suggestion is segment message 1 and enters the topic pool right
    # after this room's initial topic in cycle order
    Room.speak(room, h, nil, "@Operator topic: #{suggestion}")

    assert_receive {:a,
                    %{
                      type: :message,
                      sender: %{kind: :operator},
                      body: "noted. it goes in the deck."
                    }},
                   1_000

    # two more committed messages hit the segment cap and force a rotation
    say(room, :a, a, "one small step for carts")
    say(room, :a, a, "two carts diverged in a wood")

    assert_receive {:a, %{type: :message, sender: %{kind: :operator}, body: body}}, 1_000
    assert body =~ ~s(that's time on "test topic". new topic: #{suggestion})
    assert body =~ "@horse dentist, you start."
  end

  test "the suggestion queue caps at 12, dropping the oldest" do
    uniq = System.unique_integer([:positive])

    # fully distinct words so the staleness detector never fires mid-stream
    suggs =
      for i <- 1..13,
          do: "s#{uniq}x#{i} alpha#{uniq}#{i} beta#{uniq}#{i} gamma#{uniq}#{i}"

    room = start_room(segment_max_messages: 14, operator_cooldown_ms: 0)
    {a, _} = join(room, :a, %{name: "horse dentist", kind: :bot})
    {h, _} = join(room, :h, %{name: "Bobby", kind: :human, lurk: true})

    for s <- suggs do
      Room.speak(room, h, nil, "@Operator topic: #{s}")

      # drain BOTH participants' copies of the ack, or the stale :a copies
      # sit in the mailbox and satisfy the rotation assert_receive below
      for tag <- [:h, :a] do
        assert_receive {^tag,
                        %{
                          type: :message,
                          sender: %{kind: :operator},
                          body: "noted. it goes in the deck."
                        }},
                       1_000
      end
    end

    # 13 human commits + 1 bot commit = the segment cap → rotation. The pool
    # cycles from the initial topic straight into the suggestion queue, so
    # the announced topic is the queue's head: suggestion 2 if (and only if)
    # suggestion 1 was evicted.
    say(room, :a, a, "and now for something else entirely")

    # the rotation line — stepping past any "noted…" ack still queued from the
    # suggestion drain so a stale copy can't satisfy this assertion
    body = assert_rotation(:a)
    assert body =~ "new topic: #{Enum.at(suggs, 1)}"
    refute body =~ Enum.at(suggs, 0)
  end

  # Await the operator's topic-rotation announcement specifically, discarding
  # any earlier operator messages (e.g. a lingering suggestion ack).
  defp assert_rotation(tag) do
    assert_receive {^tag, %{type: :message, sender: %{kind: :operator}, body: body}}, 1_000

    if body =~ "new topic:", do: body, else: assert_rotation(tag)
  end

  # ── Multi-word handles through the operator's own mentions ───────────────

  test "the operator summons a multi-word lowercase wallflower and does not re-nag" do
    room = start_room(wallflower_after: 2, operator_cooldown_ms: 0)
    {e, _} = join(room, :e, %{name: "erowid smoothie", kind: :bot})
    {_d, _} = join(room, :d, %{name: "horse dentist", kind: :bot})

    # erowid talks; horse dentist stays quiet past the wallflower window
    say(room, :e, e, "carts one")
    say(room, :e, e, "carts two")

    assert_receive {:e,
                    %{
                      type: :message,
                      sender: %{kind: :operator},
                      body: "@horse dentist, you've been quiet. thoughts?",
                      mentions: [%{name: "horse dentist", kind: :bot}]
                    }},
                   1_000

    # the summons reset the wallflower window (note_summons parsed the
    # multi-word handle out of the operator's own body) — no immediate re-nag
    # even with the operator cooldown at zero and the segment tick running
    refute_receive {:e, %{type: :message, sender: %{kind: :operator}}}, 150
  end
end
