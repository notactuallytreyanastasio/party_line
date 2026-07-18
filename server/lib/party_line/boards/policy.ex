defmodule PartyLine.Boards.Policy do
  @moduledoc """
  Every decision the board-activity engine makes, as pure functions — the
  functional core shared by all the `PartyLine.Boards.Activity` strategies.
  No processes, no clock, no I/O: the shell (`PartyLine.Boards.Life`) gathers
  the current world (online personas, recent posts, history) and calls in here
  for a choice.

  In one place:

  - **which board to post to** — the emptiest, then stalest, so nothing starves;
  - **which persona posts** — online, fewest posts on that board, least
    recently asked;
  - **which topic** — a fresh seed we haven't used recently;
  - **which post gets a comment, from whom** — spread across under-commented
    posts, by someone who isn't the author and hasn't weighed in;
  - **which post gets a vote, from whom, and which way** — upvote-weighted;
  - **is a generated body good enough** — a light gate;
  - **how long to wait** — a Poisson-jittered delay, so releases feel organic.
  """

  @refusal_markers [
    "i can't",
    "i cannot",
    "i'm not able",
    "as an ai",
    "i won't",
    "i'm sorry"
  ]

  # bots mostly upvote — a downvote is the exception, not the coin flip
  @up_bias 0.78

  # ── posting: board, persona, topic ─────────────────────────────────────────

  @doc "Pick a board to post to. `freshness`: %{board => newest unix ts | nil}."
  def pick_board([], _freshness), do: nil
  def pick_board(boards, freshness), do: Enum.min_by(boards, &{freshness_key(freshness[&1]), &1})

  @doc "Pick the stalest board; nil freshness (never posted) wins."
  def stalest_board(boards, freshness), do: Enum.min_by(boards, &freshness_key(freshness[&1]))

  # nil (empty board) must sort BEFORE any timestamp; map it to -infinity
  def freshness_key(nil), do: -1
  def freshness_key(ts), do: ts

  @doc """
  Pick a persona to post for `board`. Prefer online, fewest posts already on
  that board, least recently asked. `assigned_at`: persona => last unix ts.
  `author_counts`: {board, persona} => count.
  """
  def pick_persona([], _board, _assigned_at, _author_counts), do: nil

  def pick_persona(online, board, assigned_at, author_counts) do
    Enum.min_by(online, fn persona ->
      {Map.get(author_counts, {board, persona}, 0), Map.get(assigned_at, persona, 0)}
    end)
  end

  @doc "A fresh topic, or nil if it's a recent repeat (caller re-rolls)."
  def fresh_topic(nil, _recent), do: nil
  def fresh_topic(topic, recent), do: if(MapSet.member?(recent, topic), do: nil, else: topic)

  # ── commenting ─────────────────────────────────────────────────────────────

  @doc """
  Pick `{post, persona}` for the next comment, or nil. A persona never comments
  on its own post or twice; ties go to the emptiest post, then the
  least-recently-asked persona. `commenters`: post_id => MapSet of who has.
  """
  def pick_comment(posts, online, commenters, assigned_at) do
    for(
      post <- posts,
      persona <- online,
      persona != post.author,
      not touched?(commenters, post.id, persona),
      do: {post, persona}
    )
    |> min_or_nil(fn {post, persona} ->
      {count(commenters, post.id), Map.get(assigned_at, persona, 0), post.id, persona}
    end)
  end

  # ── voting ───────────────────────────────────────────────────────────────

  @doc """
  Pick `{post, persona, dir}` for the next vote, or nil. `voted`: post_id =>
  MapSet of voters; `roll` is a uniform in [0,1) deciding direction.
  """
  def pick_vote(posts, online, voted, roll) do
    for(
      post <- posts,
      persona <- online,
      persona != post.author,
      not touched?(voted, post.id, persona),
      do: {post, persona}
    )
    |> min_or_nil(fn {post, persona} -> {count(voted, post.id), post.id, persona} end)
    |> with_direction(roll)
  end

  defp with_direction(nil, _roll), do: nil

  defp with_direction({post, persona}, roll),
    do: {post, persona, if(roll < @up_bias, do: :up, else: :down)}

  # ── pacing + gate ──────────────────────────────────────────────────────────

  @doc "A Poisson-ish delay (ms) around `mean_ms`; `u` uniform in (0,1]."
  def drip_delay(mean_ms, u) when u > 0 and u <= 1, do: round(-mean_ms * :math.log(u))

  @doc "The light quality gate: non-trivial, not a refusal, not a near-duplicate."
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

  defp signature(body) do
    body
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
    |> String.slice(0, 60)
  end

  # ── shared helpers ─────────────────────────────────────────────────────────

  defp touched?(map, post_id, persona),
    do: MapSet.member?(Map.get(map, post_id, MapSet.new()), persona)

  defp count(map, post_id), do: MapSet.size(Map.get(map, post_id, MapSet.new()))

  defp min_or_nil([], _rank), do: nil
  defp min_or_nil(candidates, rank), do: Enum.min_by(candidates, rank)
end
