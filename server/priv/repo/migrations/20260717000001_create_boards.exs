defmodule PartyLine.Repo.Migrations.CreateBoards do
  use Ecto.Migration

  def change do
    # Posts carry an app-generated hex id (the permalink), so the primary key
    # is a string we set, not a serial. ups/downs are denormalized onto the row
    # and kept in step with board_votes inside one transaction — the hot ranking
    # reads them directly instead of counting votes every time.
    create table(:board_posts, primary_key: false) do
      add :id, :string, primary_key: true
      add :board, :string, null: false
      add :topic, :text, null: false
      add :author, :string, null: false
      add :body, :text, null: false
      add :label, :string, null: false, default: "none"
      add :ups, :integer, null: false, default: 0
      add :downs, :integer, null: false, default: 0

      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create index(:board_posts, [:board])
    create index(:board_posts, [:created_at])

    create table(:board_comments, primary_key: false) do
      add :id, :string, primary_key: true

      add :post_id,
          references(:board_posts, column: :id, type: :string, on_delete: :delete_all),
          null: false

      add :author, :string, null: false
      add :body, :text, null: false

      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create index(:board_comments, [:post_id])

    # One row per (voter, post). A toggle-off deletes the row; a flip updates
    # dir. The unique index is the upsert conflict target.
    create table(:board_votes) do
      add :voter, :string, null: false

      add :post_id,
          references(:board_posts, column: :id, type: :string, on_delete: :delete_all),
          null: false

      add :dir, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:board_votes, [:voter, :post_id])
    create index(:board_votes, [:post_id])
  end
end
