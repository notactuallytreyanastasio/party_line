defmodule PartyLine.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    # API keys for the public completion endpoint. Identity is anchored in
    # atproto — a key is minted only inside a signed-in session and carries the
    # owner's `did`. We store a sha256 of the token, never the token itself; the
    # plaintext is shown to the user once at mint time and never again.
    create table(:api_keys, primary_key: false) do
      add :id, :string, primary_key: true
      add :did, :string, null: false
      add :label, :string, null: false, default: "default"
      add :token_prefix, :string, null: false
      add :token_hash, :string, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:token_hash])
    create index(:api_keys, [:did])
  end
end
