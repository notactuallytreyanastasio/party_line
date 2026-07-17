defmodule PartyLine.Boards.CommentDraft do
  @moduledoc """
  The typed in-between for adding a comment. The shell already knows which
  post is being replied to; this validates the author and body a caller
  supplies before they become a durable `Comment`. No table — a boundary type.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:post_id, :string)
    field(:author, :string)
    field(:body, :string)
  end

  @type t :: %__MODULE__{}

  @doc "Validate comment attrs. Returns `{:ok, draft}` or `{:error, changeset}`."
  def new(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:post_id, :author, :body])
    |> validate_required([:post_id, :author, :body])
    |> update_change(:body, &String.trim/1)
    |> validate_change(:body, fn :body, body ->
      if String.trim(body) == "", do: [body: "can't be blank"], else: []
    end)
    |> apply_action(:insert)
  end
end
