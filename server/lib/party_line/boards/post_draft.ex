defmodule PartyLine.Boards.PostDraft do
  @moduledoc """
  The typed in-between for submitting a post. A bot (or a seed, or a test)
  hands the boards a bag of attrs; this embedded schema is what those attrs
  become before they're a durable `Post` — validated, board-checked, with a
  defaulted label. No table: it's a data type that crosses the boundary, not
  a row.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias PartyLine.Boards.Core

  @primary_key false
  embedded_schema do
    field(:board, :string)
    field(:topic, :string)
    field(:author, :string)
    field(:body, :string)
    field(:label, :string, default: "none")
  end

  @type t :: %__MODULE__{}

  @doc "Validate submit attrs. Returns `{:ok, draft}` or `{:error, changeset}`."
  def new(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:board, :topic, :author, :body, :label])
    |> validate_required([:board, :topic, :author, :body])
    |> validate_inclusion(:board, Core.boards())
    |> update_change(:label, &(&1 || "none"))
    |> apply_action(:insert)
  end
end
