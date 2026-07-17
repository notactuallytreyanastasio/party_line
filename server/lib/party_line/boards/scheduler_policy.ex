defmodule PartyLine.Boards.SchedulerPolicy do
  @moduledoc """
  The posting scheduler's decisions, as pure functions — the functional
  core of the engine that keeps the boards fed. No processes, no clock;
  the shell (`PartyLine.Boards.Scheduler`) calls in here with the current
  world (online personas, recent history, board freshness) and gets back
  a choice.

  Policy, in one place:
  - **which board** — the one whose newest post is stalest (or emptiest),
    so nothing starves;
  - **which persona** — an online one, least-recently assigned, and not
    already over-represented as an author on that board;
  - **which topic** — a fresh seed we haven't used recently;
  - **how long to wait** — a Poisson-jittered steady interval, so posts
    land like a person occasionally posting, not a metronome;
  - **is a post good enough** — a light gate: drop empty, refusal-shaped,
    or near-duplicate bodies; everything else ships and votes decide.
  """

  @refusal_markers [
    "i can't",
    "i cannot",
    "i'm not able",
    "as an ai",
    "i won't",
    "i'm sorry"
  ]

  @doc """
  Choose a board to post to. `board_freshness` maps board => newest post's
  unix ts (or nil if empty). Emptiest first, then stalest.
  """
  def pick_board(boards, board_freshness) do
    Enum.min_by(boards, fn b -> {board_freshness[b] || :nil_low, b} end, fn -> nil end)
    |> then(fn
      nil -> Enum.random(boards)
      b -> b
    end)
  end

  # nil (empty board) must sort BEFORE any timestamp; map it to -infinity
  def freshness_key(nil), do: -1
  def freshness_key(ts), do: ts

  @doc """
  Pick a board by freshness where nil = never posted (top priority).
  `board_freshness`: %{board => unix_ts | nil}.
  """
  def stalest_board(boards, board_freshness) do
    Enum.min_by(boards, fn b -> freshness_key(board_freshness[b]) end)
  end

  @doc """
  Pick a persona to write for `board`. `online` is the list of available
  persona names; `assigned_at` maps persona => last-assigned unix ts;
  `author_counts` maps {board, persona} => how many of their posts already
  live there. Prefer online + fewest posts on this board + least recently
  assigned. Returns nil if nobody is online.
  """
  def pick_persona([], _board, _assigned_at, _author_counts), do: nil

  def pick_persona(online, board, assigned_at, author_counts) do
    Enum.min_by(online, fn persona ->
      {Map.get(author_counts, {board, persona}, 0), Map.get(assigned_at, persona, 0)}
    end)
  end

  @doc """
  Pick a fresh topic from `candidate` (a Seeds topic string) given the
  `recent` set of recently-used topics. Returns the topic, or nil if it's
  a repeat (caller re-rolls).
  """
  def fresh_topic(nil, _recent), do: nil

  def fresh_topic(topic, recent) do
    if MapSet.member?(recent, topic), do: nil, else: topic
  end

  @doc """
  A Poisson-ish delay (ms) around `mean_ms`: exponential inter-arrival so
  releases feel organic. `u` is a uniform in (0,1] (injected for tests).
  """
  def drip_delay(mean_ms, u) when u > 0 and u <= 1 do
    round(-mean_ms * :math.log(u))
  end

  @doc """
  The light quality gate. Returns true if the body is worth posting:
  non-trivial length, not a visible refusal, and not a near-duplicate of
  any body in `existing` (same-topic dedupe via a normalized prefix).
  """
  def acceptable?(body, existing) do
    b = String.trim(body || "")

    cond do
      String.length(b) < 12 -> false
      refusal?(b) -> false
      near_duplicate?(b, existing) -> false
      true -> true
    end
  end

  defp refusal?(body) do
    down = String.downcase(body)
    Enum.any?(@refusal_markers, &String.starts_with?(down, &1))
  end

  defp near_duplicate?(body, existing) do
    sig = signature(body)
    Enum.any?(existing, &(signature(&1) == sig))
  end

  # normalized 60-char signature: lowercased, punctuation/space collapsed
  defp signature(body) do
    body
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
    |> String.slice(0, 60)
  end
end
