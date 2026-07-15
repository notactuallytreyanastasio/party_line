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
            welcome_tail: 50

  @type t :: %__MODULE__{}

  @doc "Build a config from app env overlaid with per-room overrides."
  def new(overrides \\ []) do
    base = Application.get_env(:party_line, :room_config, [])
    struct!(__MODULE__, Keyword.merge(base, overrides))
  end
end
