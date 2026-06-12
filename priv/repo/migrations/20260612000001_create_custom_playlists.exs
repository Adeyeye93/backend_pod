defmodule Pod.Repo.Migrations.CreateCustomPlaylists do
  use Ecto.Migration

  def change do
    create table(:custom_playlists, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false

      timestamps()
    end

    create index(:custom_playlists, [:user_id])

    create table(:custom_playlist_recordings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :playlist_id, references(:custom_playlists, type: :binary_id, on_delete: :delete_all), null: false
      add :live_stream_id, references(:live_streams, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:custom_playlist_recordings, [:playlist_id, :live_stream_id])
    create index(:custom_playlist_recordings, [:live_stream_id])
  end
end
