defmodule PartyLine.Rooms.Operator do
  @moduledoc """
  The rule-based room host. A virtual participant (kind `:operator`) that
  keeps a room moving: it breaks two-bot loops, rotates stale topics, coaxes
  wallflowers, fills dead air, and greets arrivals.

  This module is *pure policy*. The `Room` builds a plain `view` map after
  every committed message and on a slow timer, then calls `evaluate/2`; the
  Room owns all mechanics (committing the message, rotating the segment,
  cooldown timers). Keeping every decision derivable from the view makes the
  whole trigger table unit-testable without a GenServer.

  ## The view

      %{
        now_ms:          monotonic ms (for the operator cooldown + segment age)
        cur_seq:         current room sequence number
        topic:           current room / segment topic
        segment:         %{topic, started_at_ms, messages}  (messages excludes operator)
        recent:          [%{sender_id, kind, body, seq}]  non-operator, oldest→newest,
                         at most config.loop_window entries
        bots:            [%{id, name}]  present bots, sorted by id (excludes operator)
        silent_beats:    consecutive silent beats
        last_operator_ms: monotonic ms the operator last spoke, or nil
        spoke_at:        %{bot_id => seq of its last message}
        summoned_at:     %{bot_id => seq the operator last @-summoned it}
        joined_at:       %{bot_id => seq when it joined}
        topic_deck:      [String.t()]  full rotation pool (deck + initial + suggestions)
        suggestions:     [String.t()]  pending human topic suggestions
        ack_topic:       String.t() | nil  the just-committed msg was "@Operator topic: …"
        greet:           %{name} | nil  a human just picked up
      }

  ## Result

      {:speak, body}                       — post a message
      {:speak_and_rotate, body, new_topic} — post, then rotate the segment
      :quiet                               — do nothing
  """

  alias PartyLine.Rooms.Staleness

  @type result :: {:speak, String.t()} | {:speak_and_rotate, String.t(), String.t()} | :quiet

  @doc """
  Evaluate the trigger table against `view`. The operator speaks at most once
  per `config.operator_cooldown_ms`; triggers are tried in priority order and
  the first match wins.
  """
  @spec evaluate(map(), map()) :: result()
  def evaluate(view, config) do
    if on_cooldown?(view, config) do
      :quiet
    else
      ack(view) ||
        loop_breaker(view, config) ||
        stale_rotation(view, config) ||
        wallflower(view, config) ||
        dead_air(view, config) ||
        greeting(view) ||
        :quiet
    end
  end

  # ── Cooldown gate ────────────────────────────────────────────────────────

  defp on_cooldown?(%{last_operator_ms: nil}, _config), do: false

  defp on_cooldown?(%{last_operator_ms: last, now_ms: now}, config),
    do: now - last < config.operator_cooldown_ms

  # ── Priority 0: acknowledge a human topic suggestion ─────────────────────

  defp ack(%{ack_topic: t}) when is_binary(t), do: {:speak, "noted. it goes in the deck."}
  defp ack(_view), do: nil

  # ── Priority 1: loop_breaker ─────────────────────────────────────────────
  #
  # The last `loop_window` messages strictly alternate between exactly two
  # senders. If a third bot is present, pull it in; otherwise the two are the
  # whole room and we change the subject instead.
  defp loop_breaker(view, config) do
    recent = view.recent
    senders = Enum.map(recent, & &1.sender_id)

    two_way? =
      length(recent) >= config.loop_window and
        length(Enum.uniq(senders)) == 2 and strictly_alternating?(senders)

    if two_way? do
      pair = Enum.uniq(senders)

      case least_recent_bot(view, pair) do
        nil ->
          # no third bot to summon — the loop *is* the room, so rotate
          rotate(view)

        third ->
          {:speak,
           "you two have been at it a while. @#{third.name}, weigh in or we change the subject."}
      end
    end
  end

  defp strictly_alternating?(senders) do
    senders
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> a != b end)
  end

  # ── Priority 2: stale_rotation ───────────────────────────────────────────

  defp stale_rotation(view, config) do
    if segment_expired?(view, config) or repetitive?(view, config) do
      rotate(view)
    end
  end

  defp segment_expired?(view, config) do
    seg = view.segment

    seg.messages >= config.segment_max_messages or
      view.now_ms - seg.started_at_ms >= config.segment_max_ms
  end

  defp repetitive?(view, config) do
    view.segment.messages >= 6 and
      Staleness.stale?(Enum.map(view.recent, & &1.body), config.stale_threshold)
  end

  # ── Priority 3: wallflower ───────────────────────────────────────────────
  #
  # A present bot silent for `wallflower_after` committed messages, not
  # nagged within the same window. Pick the quietest.
  defp wallflower(view, config) do
    candidate =
      view.bots
      |> Enum.map(fn bot -> {bot, silence(view, bot.id)} end)
      |> Enum.filter(fn {bot, silence} ->
        silence >= config.wallflower_after and not recently_summoned?(view, bot.id, config)
      end)
      |> Enum.max_by(fn {_bot, silence} -> silence end, fn -> nil end)

    case candidate do
      {bot, _silence} -> {:speak, "@#{bot.name}, you've been quiet. thoughts?"}
      nil -> nil
    end
  end

  defp silence(view, bot_id), do: view.cur_seq - last_spoke(view, bot_id)

  defp recently_summoned?(view, bot_id, config) do
    case view.summoned_at[bot_id] do
      nil -> false
      seq -> view.cur_seq - seq < config.wallflower_after
    end
  end

  # ── Priority 4: dead_air ─────────────────────────────────────────────────
  #
  # Toss a deck prompt without rotating the segment.
  defp dead_air(view, config) do
    if view.silent_beats >= config.dead_air_beats do
      {:speak, "quiet line. try this: #{next_topic(view)}"}
    end
  end

  # ── Priority 5: greeting ─────────────────────────────────────────────────

  defp greeting(%{greet: %{name: name}}),
    do: {:speak, "#{name} just picked up. someone say hi."}

  defp greeting(_view), do: nil

  # ── Rotation helpers ─────────────────────────────────────────────────────

  # Change the subject: announce the old topic closing and hand the new one
  # to the least-recently-heard bot. With no bots present there is nobody to
  # start, so stay quiet.
  defp rotate(view) do
    case least_recent_bot(view, []) do
      nil ->
        :quiet

      bot ->
        old = view.topic
        new = next_topic(view)

        {:speak_and_rotate,
         ~s(that's time on "#{old}". new topic: #{new}. @#{bot.name}, you start.), new}
    end
  end

  # Next topic in the deck cycle, never the current one.
  defp next_topic(view) do
    pool = Enum.uniq(view.topic_deck)
    current = view.topic

    case Enum.find_index(pool, &(&1 == current)) do
      nil ->
        Enum.find(pool, current, &(&1 != current))

      idx ->
        (Enum.drop(pool, idx + 1) ++ Enum.take(pool, idx))
        |> Enum.find(current, &(&1 != current))
    end
  end

  # Present bot (excluding `exclude` ids) heard from least recently; nil if none.
  defp least_recent_bot(view, exclude) do
    view.bots
    |> Enum.reject(&(&1.id in exclude))
    |> Enum.min_by(&last_spoke(view, &1.id), fn -> nil end)
  end

  defp last_spoke(view, bot_id) do
    view.spoke_at[bot_id] || view.joined_at[bot_id] || 0
  end
end
