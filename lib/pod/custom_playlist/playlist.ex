defmodule Pod.CustomPlaylist.Playlist do
  use Pod.Schema
  import Ecto.Changeset

  schema "custom_playlists" do
    field :name, :string

    belongs_to :user, Pod.Accounts.User
    has_many :recordings, Pod.CustomPlaylist.PlaylistRecording,
      foreign_key: :playlist_id,
      on_delete: :delete_all

    timestamps()
  end

  def changeset(playlist, attrs) do
    playlist
    |> cast(attrs, [:name, :user_id])
    |> validate_required([:name, :user_id])
    |> validate_length(:name, min: 1, max: 100)
  end
end
