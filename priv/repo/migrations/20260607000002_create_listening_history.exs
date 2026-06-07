defmodule Pod.Repo.Migrations.CreateListeningHistory do
  use Ecto.Migration

  def change do
    create table(:listening_history) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :live_stream_id, references(:live_streams, type: :binary_id, on_delete: :delete_all), null: false
      add :progress_seconds, :integer, default: 0, null: false
      add :completed, :boolean, default: false, null: false
      add :last_listened_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:listening_history, [:user_id])
    create index(:listening_history, [:live_stream_id])
    create index(:listening_history, [:user_id, :last_listened_at])
    # One row per user per stream — upserted as they listen
    create unique_index(:listening_history, [:user_id, :live_stream_id])
  end
end
