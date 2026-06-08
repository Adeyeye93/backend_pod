defmodule Pod.Playlists do
  import Ecto.Query
  alias Pod.Repo
  alias Pod.Playlist.UserPlaylist

  def list_playlist(user_id, playlist_type) do
    UserPlaylist
    |> where([p], p.user_id == ^user_id and p.playlist_type == ^playlist_type)
    |> order_by([p], desc: p.inserted_at)
    |> preload([_p], [live_stream: :creator])
    |> Repo.all()
    |> Enum.map(& &1.live_stream)
  end

  def add_to_playlist(user_id, live_stream_id, playlist_type) do
    case Repo.get_by(UserPlaylist,
           user_id: user_id,
           live_stream_id: live_stream_id,
           playlist_type: playlist_type
         ) do
      %UserPlaylist{} ->
        {:error, :already_exists}

      nil ->
        %UserPlaylist{}
        |> UserPlaylist.changeset(%{
          user_id: user_id,
          live_stream_id: live_stream_id,
          playlist_type: playlist_type
        })
        |> Repo.insert()
    end
  end

  def remove_from_playlist(user_id, live_stream_id, playlist_type) do
    case Repo.get_by(UserPlaylist,
           user_id: user_id,
           live_stream_id: live_stream_id,
           playlist_type: playlist_type
         ) do
      nil ->
        {:error, :not_found}

      %UserPlaylist{} = entry ->
        Repo.delete(entry)
        {:ok, :removed}
    end
  end

  def valid_type?(type), do: type in UserPlaylist.valid_types()
end
