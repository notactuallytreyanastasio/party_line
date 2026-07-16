defmodule PartyLine.Rooms.Config do
  @moduledoc """
  Timing and tuning knobs for a room's turn-taking director.

  Every duration is milliseconds. Tests inject tiny values so the whole
  state machine can be exercised in real time without sleeps.
  """

  defstruct cooldown_min: 3_000,
            cooldown_max: 7_000,
            # simulated "reading time" added to cooldown per char of the last message
            reading_ms_per_char: 30,
            reading_ms_cap: 6_000,
            bid_window: 1_500,
            fast_bid_window: 1_200,
            grant_deadline: 25_000,
            preempt_cooldown: 800,
            silence_backoff: [4_000, 8_000, 15_000, 30_000],
            urge_threshold: 0.2,
            max_strikes: 3,
            strike_penalty: 300_000,
            transcript_keep: 200,
            welcome_tail: 50,
            # ── Operator (rule-based room host) ─────────────────────────────
            # Defaulted from app env :party_line, :operator[:enabled]; a
            # per-room `operator:` opt overrides it in Room.init/1.
            operator_enabled: false,
            # segment clock: rotate the topic when either bound is crossed
            segment_max_messages: 24,
            segment_max_ms: 480_000,
            # slow timer so quiet rooms still rotate / break dead air
            segment_tick_ms: 30_000,
            # the operator speaks at most once per this window
            operator_cooldown_ms: 45_000,
            # loop_breaker inspects this many recent (non-operator) messages
            loop_window: 6,
            # mean pairwise word-trigram Jaccard above this reads as stale
            stale_threshold: 0.35,
            # a bot silent this many committed messages is a wallflower
            wallflower_after: 15,
            # this many consecutive silent beats is dead air
            dead_air_beats: 4,
            # cheeky, in-register topics the operator rotates through
            topic_deck: [
              "raccoons and the ethics of the unlatched bin",
              "which trash panda would win a jewel heist",
              "the secret nightlife of city pigeons",
              "best street food you'd fight a seagull for",
              "backyard astronomy: what's actually up there tonight",
              "urban foxes and other polite intruders",
              "folklore of the crossroads at 3am",
              "the moon landing, but make it a potluck",
              "opossums: misunderstood or just weird",
              "diner coffee vs the heat death of the universe"
            ]

  @type t :: %__MODULE__{}

  @doc "Build a config from app env overlaid with per-room overrides."
  def new(overrides \\ []) do
    base = Application.get_env(:party_line, :room_config, [])
    operator_default = Application.get_env(:party_line, :operator, [])[:enabled] || false

    merged =
      [operator_enabled: operator_default]
      |> Keyword.merge(base)
      |> Keyword.merge(overrides)

    struct!(__MODULE__, merged)
  end
end
