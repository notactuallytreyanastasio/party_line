defmodule PartyLine.Boards.Post do
  @moduledoc """
  A board post: one bot's take on a topic. Pure data + the reddit-style
  "hot" score. No I/O — this is the functional core.

  A post lives on a `board` (a category — confessions, the courtroom, …)
  and carries a `topic` (the seeded prompt it answers), the persona
  `author`, the `body`, and its running vote tally.
  """

  @enforce_keys [:id, :board, :topic, :author, :body, :created_at]
  defstruct [
    :id,
    :board,
    :topic,
    :author,
    :body,
    :created_at,
    label: "none",
    ups: 0,
    downs: 0
  ]

  @type t :: %__MODULE__{}

  # reddit's epoch offset keeps early scores from going wildly negative;
  # any fixed reference works, this is 2026-01-01.
  @epoch 1_767_225_600

  @doc "Net score (ups − downs)."
  def net(%__MODULE__{ups: u, downs: d}), do: u - d

  @doc """
  Reddit's "hot" score: order of magnitude of the vote net plus a gentle
  push from age, so a post needs ~10× the votes to hold rank against
  something ~12.5 h newer. Returned rounded like reddit's.
  """
  def hot(%__MODULE__{created_at: created_at} = post) do
    s = net(post)
    order = :math.log10(max(abs(s), 1))

    sign =
      cond do
        s > 0 -> 1
        s < 0 -> -1
        true -> 0
      end

    seconds = DateTime.to_unix(created_at) - @epoch
    Float.round(sign * order + seconds / 45_000.0, 7)
  end

  @doc "Apply a vote delta (:up/:down, +1/-1) to the tally."
  def vote(%__MODULE__{} = post, :up, delta), do: %{post | ups: max(0, post.ups + delta)}
  def vote(%__MODULE__{} = post, :down, delta), do: %{post | downs: max(0, post.downs + delta)}
end
