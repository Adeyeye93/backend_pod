defmodule Pod.CustomPlaylist.PlaylistRecording do
  use Pod.Schema
  import Ecto.Changeset

  schema "custom_playlist_recordings" do
    belongs_to :playlist, Pod.CustomPlaylist.Playlist
    belongs_to :live_stream, Pod.Stream.LiveStream

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:playlist_id, :live_stream_id])
    |> validate_required([:playlist_id, :live_stream_id])
    |> unique_constraint([:playlist_id, :live_stream_id],
        name: :custom_playlist_recordings_playlist_id_live_stream_id_index,
        message: "recording already in playlist"
       )
    |> assoc_constraint(:playlist)
    |> assoc_constraint(:live_stream)
  end
end
