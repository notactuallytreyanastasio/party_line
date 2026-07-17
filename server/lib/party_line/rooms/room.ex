defmodule PartyLine.Rooms.Room do
  @moduledoc """
  A party line room. One GenServer per room — the process is both the
  message router and the turn-taking director, which makes it the single
  writer of the room's message sequence (no locks, no seq races).

  ## Director state machine

      :idle ──(bot joins)──▶ :cooldown ──▶ :bidding ──▶ :granted ──▶ :cooldown
                                  ▲            │  no bids ≥ threshold  │
                                  │            ▼ (silence backoff)     │
                                  └──────── :bidding ◀── timeout ──────┘

  * `:cooldown` — the room "reads" the last message; nobody may be granted.
  * `:bidding`  — a `beat` is open; bots submit urge bids until the window
    closes, then the best (urge × fairness) bid wins, or the beat passes in
    silence and the next beat backs off progressively.
  * `:granted`  — one bot holds the floor with a deadline. A timeout costs
    a strike (three strikes → temporary grant quarantine) and re-opens
    bidding immediately.

  Humans never bid and are never blocked: a human `speak` broadcasts
  immediately, revokes any live grant (`preempted` — the in-flight reply
  was generated against a stale context), invalidates any open beat, and
  schedules a fast beat so an @-mentioned bot can answer promptly while a
  human→human exchange draws no qualifying bids and passes in silence.

  Participants receive events as `{:party_line, map}` — bot sockets encode
  the map to JSON, the LiveView renders it directly.
  """

  use GenServer, restart: :transient

  alias PartyLine.Mentions
  alias PartyLine.Rooms.{Config, Operator}

  # ── Client API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || nil)
  end

  @doc """
  Join as a participant. `attrs` requires `:name` and `:kind` (:bot |
  :human); `:lurk` (humans only) joins invisibly. The calling process (or
  `attrs[:pid]`) is monitored and receives all subsequent room events.
  """
  def join(room, attrs) do
    GenServer.call(room, {:join, Map.put_new(attrs, :pid, self())})
  end

  def announce(room, participant_id), do: GenServer.call(room, {:announce, participant_id})

  def bid(room, participant_id, beat_id, urge),
    do: GenServer.cast(room, {:bid, participant_id, beat_id, urge})

  @doc "Bots pass their live grant_id; humans pass nil."
  def speak(room, participant_id, grant_id, body, client_ref \\ nil),
    do: GenServer.cast(room, {:speak, participant_id, grant_id, body, client_ref})

  def leave(room, participant_id), do: GenServer.cast(room, {:leave, participant_id})

  def snapshot(room), do: GenServer.call(room, :snapshot)

  # ── State ───────────────────────────────────────────────────────────────

  defmodule P do
    @moduledoc false
    defstruct [:id, :name, :kind, :pid, :monitor, visible: true]
  end

  defstruct id: nil,
            topic: nil,
            config: nil,
            participants: %{},
            next_participant: 1,
            seq: 0,
            transcript: [],
            phase: :idle,
            beat_counter: 0,
            current_beat: nil,
            bids: %{},
            grant_counter: 0,
            current_grant: nil,
            timer: nil,
            strikes: %{},
            quarantined: %{},
            silent_beats: 0,
            # ── Operator (rule-based host) ──────────────────────────────────
            initial_topic: nil,
            segment: nil,
            last_operator_ms: nil,
            # set when a trigger fires while a grant is live; drained on
            # the next grant resolution
            operator_pending: false,
            # seq bookkeeping for the wallflower / rotation policies
            spoke_at: %{},
            summoned_at: %{},
            joined_at: %{},
            # capped queue of human "@Operator topic: …" suggestions
            suggestions: []

  # ── Callbacks ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    config =
      case Keyword.fetch(opts, :operator) do
        {:ok, enabled} -> %{base_config(opts) | operator_enabled: enabled}
        :error -> base_config(opts)
      end

    topic = Keyword.get(opts, :topic, "whatever is on your mind")
    now = System.monotonic_time(:millisecond)

    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      topic: topic,
      initial_topic: topic,
      config: config,
      segment: %{topic: topic, started_at_ms: now, messages: 0}
    }

    state = if config.operator_enabled, do: add_operator(state), else: state
    if config.operator_enabled, do: schedule_segment_tick(config)

    {:ok, state}
  end

  defp base_config(opts), do: Keyword.get(opts, :config) || Config.new()

  # The operator is a pid-less, unmonitored participant: it appears in the
  # roster and speaks through the normal commit path but has no socket and
  # never bids or receives beats/grants.
  defp add_operator(state) do
    op = %P{id: "p-operator", name: "Operator", kind: :operator, pid: nil, monitor: nil}
    %{state | participants: Map.put(state.participants, op.id, op)}
  end

  defp schedule_segment_tick(config),
    do: Process.send_after(self(), :segment_tick, config.segment_tick_ms)

  @impl true
  def handle_call({:join, attrs}, _from, state) do
    id = "p-#{state.next_participant}"
    kind = attrs.kind
    visible = not (kind == :human and Map.get(attrs, :lurk, false))

    participant = %P{
      id: id,
      name: attrs.name,
      kind: kind,
      pid: attrs.pid,
      monitor: Process.monitor(attrs.pid),
      visible: visible
    }

    state = %{
      state
      | participants: Map.put(state.participants, id, participant),
        next_participant: state.next_participant + 1
    }

    if visible, do: broadcast_presence(state, participant, :joined, except: id)

    welcome = %{
      type: :welcome,
      participant_id: id,
      room: %{id: state.id, topic: state.topic},
      roster: roster(state),
      transcript: state.transcript |> Enum.take(state.config.welcome_tail) |> Enum.reverse()
    }

    state = maybe_wake(state, kind)
    state = if kind == :bot, do: note_joined(state, id), else: state

    # a human picking up gives the operator someone to introduce
    state =
      if visible and kind == :human,
        do: maybe_run_operator(state, greet: %{name: participant.name}),
        else: state

    {:reply, {:ok, welcome}, state}
  end

  def handle_call({:announce, participant_id}, _from, state) do
    case state.participants[participant_id] do
      %P{visible: false} = p ->
        p = %{p | visible: true}
        state = put_in(state.participants[participant_id], p)
        broadcast_presence(state, p, :announced)

        state =
          if p.kind == :human,
            do: maybe_run_operator(state, greet: %{name: p.name}),
            else: state

        {:reply, :ok, state}

      %P{} ->
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :unknown_participant}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       topic: state.topic,
       phase: state.phase,
       roster: roster(state),
       transcript: Enum.reverse(state.transcript),
       silent_beats: state.silent_beats,
       strikes: state.strikes
     }, state}
  end

  @impl true
  def handle_cast({:bid, participant_id, beat_id, urge}, state) do
    with %{id: ^beat_id} <- state.current_beat,
         %P{kind: :bot} <- state.participants[participant_id] do
      {:noreply, %{state | bids: Map.put(state.bids, participant_id, clamp(urge))}}
    else
      # stale beat_id, unknown participant, or a human trying to bid: ignore
      _ -> {:noreply, state}
    end
  end

  def handle_cast({:speak, participant_id, grant_id, body, client_ref}, state) do
    case state.participants[participant_id] do
      %P{kind: :human} = p -> {:noreply, human_speak(state, p, body)}
      %P{kind: :bot} = p -> {:noreply, bot_speak(state, p, grant_id, body, client_ref)}
      nil -> {:noreply, state}
    end
  end

  def handle_cast({:leave, participant_id}, state) do
    {:noreply, drop_participant(state, participant_id)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.participants, fn {_, p} -> p.pid == pid end) do
      {id, _} -> {:noreply, drop_participant(state, id)}
      nil -> {:noreply, state}
    end
  end

  # Timer messages carry the id they were armed for; stale ones are ignored.
  def handle_info({:cooldown_over, counter}, %{beat_counter: counter} = state),
    do: {:noreply, open_beat(state, state.config.bid_window)}

  def handle_info({:beat_over, beat_id}, %{current_beat: %{id: beat_id}} = state),
    do: {:noreply, close_beat(state)}

  def handle_info({:grant_timeout, grant_id}, %{current_grant: %{id: grant_id}} = state),
    do: {:noreply, grant_timeout(state)}

  # Slow operator heartbeat: rotates stale/aged segments and fills dead air in
  # quiet rooms where no commit is arriving to drive evaluation.
  def handle_info(:segment_tick, state) do
    state = maybe_run_operator(state)
    if state.config.operator_enabled, do: schedule_segment_tick(state.config)
    {:noreply, state}
  end

  def handle_info(_stale, state), do: {:noreply, state}

  # ── Director: beats and bids ────────────────────────────────────────────

  # Wake the director when the first bot joins an idle room.
  defp maybe_wake(%{phase: :idle} = state, :bot), do: schedule_cooldown(state)
  defp maybe_wake(state, _kind), do: state

  defp schedule_cooldown(state, extra_ms \\ 0) do
    cfg = state.config
    last = List.first(state.transcript)

    reading =
      case last do
        nil -> 0
        %{body: body} -> min(cfg.reading_ms_cap, String.length(body) * cfg.reading_ms_per_char)
      end

    delay =
      cfg.cooldown_min + :rand.uniform(max(1, cfg.cooldown_max - cfg.cooldown_min)) +
        reading + extra_ms

    counter = state.beat_counter + 1
    state = cancel_timer(state)

    %{
      state
      | phase: :cooldown,
        beat_counter: counter,
        current_beat: nil,
        bids: %{},
        timer: Process.send_after(self(), {:cooldown_over, counter}, delay)
    }
  end

  defp open_beat(state, window_ms) do
    if Enum.any?(state.participants, fn {_, p} -> p.kind == :bot end) do
      counter = state.beat_counter + 1
      beat_id = "b-#{counter}"
      state = cancel_timer(state)

      beat = %{type: :beat, beat_id: beat_id, window_ms: window_ms, last_seq: state.seq}
      broadcast(state, beat, only_kind: :bot)

      %{
        state
        | phase: :bidding,
          beat_counter: counter,
          current_beat: %{id: beat_id},
          bids: %{},
          timer: Process.send_after(self(), {:beat_over, beat_id}, window_ms)
      }
    else
      # no bots connected: go idle until one joins
      %{cancel_timer(state) | phase: :idle, current_beat: nil, bids: %{}}
    end
  end

  defp close_beat(state) do
    now = System.monotonic_time(:millisecond)

    winner =
      state.bids
      |> Enum.map(fn {pid_id, urge} -> {pid_id, urge * fairness(state, pid_id)} end)
      |> Enum.reject(fn {pid_id, score} ->
        score < state.config.urge_threshold or quarantined?(state, pid_id, now)
      end)
      |> case do
        [] -> nil
        scored -> scored |> Enum.shuffle() |> Enum.max_by(fn {_, score} -> score end)
      end

    state = %{state | current_beat: nil, bids: %{}}

    case winner do
      nil ->
        # Silence is allowed — back off progressively before the next beat.
        backoff = Enum.at(state.config.silence_backoff, min(state.silent_beats, 3))
        state = %{state | silent_beats: state.silent_beats + 1, phase: :cooldown}
        counter = state.beat_counter + 1
        state = cancel_timer(state)

        %{
          state
          | beat_counter: counter,
            timer: Process.send_after(self(), {:cooldown_over, counter}, backoff)
        }

      {participant_id, _score} ->
        grant(state, participant_id)
    end
  end

  # Server-side fairness applied on top of the self-reported urge, so a
  # greedy bot cannot monologue: hard zero for following your own message,
  # dampened if you spoke within the last two.
  # Graduated floor-holding: a bot MAY continue its own thought (dampened),
  # so one voice can lead a room while others chime in when they actually
  # have something — but a run is capped so nobody monologues unopposed.
  defp fairness(state, participant_id) do
    consecutive =
      state.transcript
      |> Enum.take_while(&(&1.sender.participant_id == participant_id))
      |> length()

    recent =
      state.transcript
      |> Enum.take(2)
      |> Enum.map(& &1.sender.participant_id)

    cond do
      consecutive >= state.config.max_consecutive -> 0.0
      consecutive >= 1 -> state.config.self_follow_penalty
      match?([_, ^participant_id], recent) -> 0.5
      true -> 1.0
    end
  end

  defp quarantined?(state, participant_id, now) do
    case state.quarantined[participant_id] do
      nil -> false
      until -> now < until
    end
  end

  # ── Director: grants ────────────────────────────────────────────────────

  defp grant(state, participant_id) do
    counter = state.grant_counter + 1
    grant_id = "g-#{counter}"
    p = state.participants[participant_id]
    state = cancel_timer(state)

    send_to(p, %{
      type: :grant,
      grant_id: grant_id,
      deadline_ms: state.config.grant_deadline,
      context_seq: state.seq
    })

    %{
      state
      | phase: :granted,
        grant_counter: counter,
        current_grant: %{id: grant_id, participant_id: participant_id},
        silent_beats: 0,
        timer: Process.send_after(self(), {:grant_timeout, grant_id}, state.config.grant_deadline)
    }
  end

  defp grant_timeout(state) do
    %{id: grant_id, participant_id: participant_id} = state.current_grant
    p = state.participants[participant_id]
    if p, do: send_to(p, %{type: :grant_revoked, grant_id: grant_id, reason: :timeout})

    strikes = Map.update(state.strikes, participant_id, 1, &(&1 + 1))

    quarantined =
      if strikes[participant_id] >= state.config.max_strikes do
        until = System.monotonic_time(:millisecond) + state.config.strike_penalty
        Map.put(state.quarantined, participant_id, until)
      else
        state.quarantined
      end

    state = %{state | current_grant: nil, strikes: strikes, quarantined: quarantined}
    # the room was already waiting — re-open bidding immediately
    state = open_beat(state, state.config.bid_window)
    resolve_pending(state)
  end

  defp revoke_grant(state, reason) do
    case state.current_grant do
      nil ->
        state

      %{id: grant_id, participant_id: participant_id} ->
        p = state.participants[participant_id]
        if p, do: send_to(p, %{type: :grant_revoked, grant_id: grant_id, reason: reason})
        %{cancel_timer(state) | current_grant: nil}
    end
  end

  # ── Speaking ────────────────────────────────────────────────────────────

  defp bot_speak(state, p, grant_id, body, client_ref) do
    case state.current_grant do
      %{id: ^grant_id, participant_id: participant_id} when participant_id == p.id ->
        state = %{
          cancel_timer(state)
          | current_grant: nil,
            strikes: Map.delete(state.strikes, p.id)
        }

        state =
          state
          |> commit_message(p, body)
          |> bump_segment()
          |> note_spoke(p)
          |> schedule_cooldown()

        maybe_run_operator(state)

      _ ->
        # dead or foreign grant: the text was generated against a stale
        # context — drop it rather than double-speak
        send_to(p, %{
          type: :speak_rejected,
          grant_id: grant_id,
          client_ref: client_ref,
          reason: :grant_expired
        })

        state
    end
  end

  defp human_speak(state, p, body) do
    state =
      state
      |> revoke_grant(:preempted)
      |> commit_message(p, body)
      |> bump_segment()

    {state, operator_opts} = maybe_capture_suggestion(state, body)

    # invalidate any open beat (bids for it are now stale) and schedule a
    # fast beat so an @-mentioned bot can answer promptly
    state = %{state | current_beat: nil, bids: %{}, silent_beats: 0}
    counter = state.beat_counter + 1
    state = cancel_timer(state)

    state = %{
      state
      | phase: :cooldown,
        beat_counter: counter,
        timer:
          Process.send_after(
            self(),
            {:cooldown_over, counter},
            state.config.preempt_cooldown
          )
    }

    maybe_run_operator(state, operator_opts)
  end

  # "@Operator topic: <text>" (case-insensitive) enqueues a topic suggestion
  # (queue capped at 12) and asks the operator to acknowledge it.
  defp maybe_capture_suggestion(state, body) do
    case Regex.run(~r/^\s*@operator\s+topic:\s*(\S.*?)\s*$/i, body) do
      [_, text] ->
        suggestions = Enum.take(state.suggestions ++ [text], -12)
        {%{state | suggestions: suggestions}, ack_topic: text}

      _ ->
        {state, []}
    end
  end

  defp commit_message(state, %P{} = sender, body) do
    seq = state.seq + 1
    mentions = Mentions.parse(body, roster(state))

    message = %{
      type: :message,
      room_id: state.id,
      seq: seq,
      message_id: "m-#{seq}",
      ts: DateTime.to_iso8601(DateTime.utc_now()),
      sender: %{participant_id: sender.id, name: sender.name, kind: sender.kind},
      body: body,
      mentions:
        Enum.map(mentions, &%{participant_id: &1.participant_id, name: &1.name, kind: &1.kind})
    }

    broadcast(state, message)
    PartyLine.TranscriptLog.append(state.id, message)
    PartyLine.Memory.Ingest.record_message(state.id, message)

    %{
      state
      | seq: seq,
        transcript: Enum.take([message | state.transcript], state.config.transcript_keep)
    }
  end

  # ── Operator (rule-based host) ──────────────────────────────────────────

  # Run the policy, unless the operator is disabled or a grant is live — in
  # the latter case remember to try again once the floor clears (an operator
  # message must never race a bot's in-flight reply).
  defp maybe_run_operator(state, opts \\ []) do
    cond do
      not state.config.operator_enabled -> state
      state.phase == :granted -> %{state | operator_pending: true}
      true -> run_operator(%{state | operator_pending: false}, opts)
    end
  end

  defp resolve_pending(%{operator_pending: true} = state),
    do: maybe_run_operator(%{state | operator_pending: false})

  defp resolve_pending(state), do: state

  defp run_operator(state, opts) do
    case Operator.evaluate(build_view(state, opts), state.config) do
      :quiet ->
        state

      {:speak, body} ->
        operator_commit(state, body)

      {:speak_and_rotate, body, new_topic} ->
        state |> operator_commit(body) |> rotate_segment(new_topic)
    end
  end

  # The operator speaks through the normal commit path (seq, transcript,
  # JSONL, memory ingest) but is bookkept separately: it never recurses, its
  # message doesn't count toward the segment, and any bot it @-summons has its
  # wallflower cooldown reset.
  defp operator_commit(state, body) do
    op = state.participants["p-operator"]

    state
    |> commit_message(op, body)
    |> note_summons(body)
    |> Map.put(:last_operator_ms, System.monotonic_time(:millisecond))
  end

  defp rotate_segment(state, new_topic) do
    now = System.monotonic_time(:millisecond)
    %{state | topic: new_topic, segment: %{topic: new_topic, started_at_ms: now, messages: 0}}
  end

  # Everything the policy needs, derived from room state. Operator messages are
  # excluded from the loop / staleness windows and the segment message count.
  defp build_view(state, opts) do
    recent =
      state.transcript
      |> Enum.reject(&(&1.sender.kind == :operator))
      |> Enum.take(state.config.loop_window)
      |> Enum.reverse()
      |> Enum.map(
        &%{sender_id: &1.sender.participant_id, kind: &1.sender.kind, body: &1.body, seq: &1.seq}
      )

    %{
      now_ms: System.monotonic_time(:millisecond),
      cur_seq: state.seq,
      topic: state.topic,
      segment: state.segment,
      recent: recent,
      bots: present_bots(state),
      silent_beats: state.silent_beats,
      last_operator_ms: state.last_operator_ms,
      spoke_at: state.spoke_at,
      summoned_at: state.summoned_at,
      joined_at: state.joined_at,
      topic_deck: topic_pool(state),
      suggestions: state.suggestions,
      ack_topic: opts[:ack_topic],
      greet: opts[:greet]
    }
  end

  defp present_bots(state) do
    state.participants
    |> Map.values()
    |> Enum.filter(&(&1.visible and &1.kind == :bot))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&%{id: &1.id, name: &1.name})
  end

  # Each room walks the deck in its own order (rotated by a hash of the room
  # id) — otherwise every line converges onto the same deck sequence and the
  # whole exchange ends up discussing the moon-landing potluck in unison.
  defp topic_pool(state) do
    # the built-in deck + this room's own topics + human suggestions +
    # a sprinkle of seeded "reddit with a twist" prompts (the network feed)
    seeded = seeded_topics(state.config)

    pool =
      Enum.uniq(state.config.topic_deck ++ seeded ++ [state.initial_topic] ++ state.suggestions)

    offset = :erlang.phash2(state.id, max(1, length(pool)))
    {back, front} = Enum.split(pool, offset)
    front ++ back
  end

  defp seeded_topics(config) do
    if Map.get(config, :seeded_topics, true) do
      for _ <- 1..3, t = safe_seed_topic(), t != nil, uniq: true, do: t
    else
      []
    end
  end

  defp safe_seed_topic do
    PartyLine.Seeds.topic()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp note_joined(state, id), do: %{state | joined_at: Map.put(state.joined_at, id, state.seq)}

  defp note_spoke(state, %P{id: id}),
    do: %{state | spoke_at: Map.put(state.spoke_at, id, state.seq)}

  # Any bot the operator @-mentions has its wallflower cooldown refreshed.
  defp note_summons(state, body) do
    ids =
      body
      |> Mentions.parse(roster(state))
      |> Enum.filter(&(&1.kind == :bot))
      |> Enum.map(& &1.participant_id)

    summoned_at =
      Enum.reduce(ids, state.summoned_at, &Map.put(&2, &1, state.seq))

    %{state | summoned_at: summoned_at}
  end

  # Only bot/human commits reach here (the operator commits via operator_commit),
  # so every counted message is genuinely a non-operator one.
  defp bump_segment(state), do: update_in(state.segment.messages, &(&1 + 1))

  # ── Participants ────────────────────────────────────────────────────────

  defp drop_participant(state, participant_id) do
    case Map.pop(state.participants, participant_id) do
      {nil, _} ->
        state

      {p, participants} ->
        Process.demonitor(p.monitor, [:flush])
        state = %{state | participants: participants}
        if p.visible, do: broadcast_presence(state, p, :left)

        state =
          case state.current_grant do
            %{participant_id: ^participant_id} ->
              open_beat(%{cancel_timer(state) | current_grant: nil}, state.config.bid_window)

            _ ->
              state
          end

        idle_if_no_bots(state)
    end
  end

  defp idle_if_no_bots(state) do
    if Enum.any?(state.participants, fn {_, q} -> q.kind == :bot end) do
      state
    else
      %{cancel_timer(state) | phase: :idle, current_beat: nil, bids: %{}}
    end
  end

  defp roster(state) do
    state.participants
    |> Map.values()
    |> Enum.filter(& &1.visible)
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&%{participant_id: &1.id, name: &1.name, kind: &1.kind})
  end

  # ── Plumbing ────────────────────────────────────────────────────────────

  defp broadcast_presence(state, p, event, opts \\ []) do
    PartyLine.Memory.Ingest.record_presence(state.id, event, %{
      participant_id: p.id,
      name: p.name,
      kind: p.kind
    })

    broadcast(
      state,
      %{
        type: :presence,
        room_id: state.id,
        event: event,
        participant: %{participant_id: p.id, name: p.name, kind: p.kind}
      },
      opts
    )
  end

  defp broadcast(state, event, opts \\ []) do
    only_kind = opts[:only_kind]
    except = opts[:except]

    for {_, p} <- state.participants,
        p.pid != nil,
        only_kind == nil or p.kind == only_kind,
        p.id != except do
      send_to(p, event)
    end

    :ok
  end

  defp send_to(%P{pid: pid}, event), do: send(pid, {:party_line, event})

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp clamp(urge) when is_number(urge), do: urge |> max(0.0) |> min(1.0)
  defp clamp(_), do: 0.0
end
