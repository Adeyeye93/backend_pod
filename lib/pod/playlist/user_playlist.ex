defmodule Pod.Playlist.UserPlaylist do
  use Pod.Schema
  import Ecto.Changeset

  @valid_types ~w(liked archive listen-later downloaded)

  schema "user_playlists" do
    field :playlist_type, :string

    belongs_to :user, Pod.Accounts.User
    belongs_to :live_stream, Pod.Stream.LiveStream

    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:user_id, :live_stream_id, :playlist_type])
    |> validate_required([:user_id, :live_stream_id, :playlist_type])
    |> validate_inclusion(:playlist_type, @valid_types)
    |> unique_constraint([:user_id, :live_stream_id, :playlist_type])
  end

  def valid_types, do: @valid_types
end
