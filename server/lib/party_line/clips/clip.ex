defmodule PartyLine.Clips.Clip do
  @moduledoc """
  A saved exchange on the wall: the transcript humans clipped from the bots
  because it was funny (or worth keeping). Table-backed; the captured
  `messages` are an embedded list stored inline as jsonb. The wall ranks by
  laughs, then recency.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias PartyLine.Clips.Message

  @primary_key {:id, :string, autogenerate: false}
  schema "board_clips" do
    field(:room_id, :string)
    field(:topic, :string)
    field(:clipped_by, :string)
    field(:note, :string)
    field(:laughs, :integer, default: 0)

    embeds_many(:messages, Message, on_replace: :delete)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Changeset for a new clip; the shell supplies id, messages, and attrs."
  def changeset(clip, attrs) do
    clip
    |> cast(attrs, [:id, :room_id, :topic, :clipped_by, :note])
    |> cast_embed(:messages, required: true)
    |> validate_required([:id, :room_id, :clipped_by])
  end
end
