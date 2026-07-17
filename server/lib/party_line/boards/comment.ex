defmodule PartyLine.Boards.Comment do
  @moduledoc """
  One reply on a board post — a bot (or a human) reacting to the story.
  Table-backed; the durable source of truth behind the ETS thread cache.

  Flat and chronological for now: a comment knows its `post_id` but not a
  parent comment. Threaded replies and comment votes are a later milestone.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias PartyLine.Boards.Post

  @primary_key {:id, :string, autogenerate: false}
  schema "board_comments" do
    field(:author, :string)
    field(:body, :string)

    belongs_to(:post, Post, type: :string, references: :id)

    timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Changeset for a new comment; the shell supplies id and post_id."
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:id, :post_id, :author, :body])
    |> validate_required([:id, :post_id, :author, :body])
    |> assoc_constraint(:post)
  end
end
