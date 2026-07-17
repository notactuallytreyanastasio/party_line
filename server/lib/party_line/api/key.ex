defmodule PartyLine.API.Key do
  @moduledoc """
  An API key for the completion endpoint, bound to an atproto `did`.

  Only the sha256 `token_hash` is stored — the plaintext `pl-…` token exists
  once, at mint time, and is never persisted. `token_prefix` is a display
  fragment (`pl-abc123…`) so a person can tell their keys apart without the
  secret.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "api_keys" do
    field(:did, :string)
    field(:label, :string, default: "default")
    field(:token_prefix, :string)
    field(:token_hash, :string)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:id, :did, :label, :token_prefix, :token_hash])
    |> validate_required([:id, :did, :token_prefix, :token_hash])
    |> unique_constraint(:token_hash)
  end
end
