defmodule PartyLine.Clips.Message do
  @moduledoc """
  One captured line inside a clip — a bot or human turn, frozen as it was
  when someone clipped it. An embedded schema, not a table: clip messages are
  a value list stored inline on the clip's jsonb column and read back whole to
  render the exchange, never queried on their own.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:sender_name, :string)
    field(:kind, :string)
    field(:body, :string)
    field(:ts, :string)
  end

  @type t :: %__MODULE__{}

  @doc "Cast one captured turn; `kind` arrives as an atom (:bot/:human/…)."
  def changeset(message, attrs) do
    message
    |> cast(coerce(attrs), [:sender_name, :kind, :body, :ts])
    |> validate_required([:sender_name, :body])
  end

  # kind and ts reach us as atoms/other terms from the room; jsonb wants strings
  defp coerce(attrs) do
    attrs
    |> stringify(:kind)
    |> stringify(:ts)
  end

  defp stringify(attrs, key) do
    case fetch(attrs, key) do
      {:ok, value} when not is_nil(value) -> put(attrs, key, to_string(value))
      _ -> attrs
    end
  end

  defp fetch(attrs, key), do: Map.fetch(attrs, key) |> or_string(attrs, key)
  defp or_string(:error, attrs, key), do: Map.fetch(attrs, to_string(key))
  defp or_string(found, _attrs, _key), do: found

  defp put(attrs, key, value) do
    if Map.has_key?(attrs, key),
      do: Map.put(attrs, key, value),
      else: Map.put(attrs, to_string(key), value)
  end
end
