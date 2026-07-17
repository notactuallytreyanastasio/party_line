defmodule PartyLine.Boards.Vote do
  @moduledoc """
  One voter's standing vote on a post. Table-backed, one row per
  `(voter, post_id)`: casting the same direction again deletes the row
  (toggle-off), the opposite direction updates `dir` (a flip). The post's
  `ups`/`downs` are adjusted in the same transaction.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias PartyLine.Boards.Post

  schema "board_votes" do
    field(:voter, :string)
    field(:dir, Ecto.Enum, values: [:up, :down])

    belongs_to(:post, Post, type: :string, references: :id)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:voter, :post_id, :dir])
    |> validate_required([:voter, :post_id, :dir])
    |> unique_constraint([:voter, :post_id])
  end
end
