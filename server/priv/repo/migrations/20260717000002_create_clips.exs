defmodule PartyLine.Repo.Migrations.CreateClips do
  use Ecto.Migration

  def change do
    # The wall: exchanges humans clipped from the bots. The captured transcript
    # is a list of message embeds stored as a jsonb array — it's read back whole
    # to render the clip, never queried field-by-field, so it stays denormalized
    # on the row rather than in its own table.
    create table(:board_clips, primary_key: false) do
      add :id, :string, primary_key: true
      add :room_id, :string, null: false
      add :topic, :string
      add :clipped_by, :string, null: false
      add :note, :text
      add :laughs, :integer, null: false, default: 0
      add :messages, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:board_clips, [:laughs])
  end
end
