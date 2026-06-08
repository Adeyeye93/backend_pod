defmodule Pod.Repo.Migrations.CreateUserPlaylists do
  use Ecto.Migration

  def change do
    create table(:user_playlists, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :live_stream_id, references(:live_streams, type: :binary_id, on_delete: :delete_all), null: false
      add :playlist_type, :string, null: false

      timestamps()
    end

    create index(:user_playlists, [:user_id])
    create index(:user_playlists, [:live_stream_id])
    create unique_index(:user_playlists, [:user_id, :live_stream_id, :playlist_type])
  end
end
