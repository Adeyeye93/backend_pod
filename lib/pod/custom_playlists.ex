defmodule Pod.CustomPlaylists do
  import Ecto.Query
  alias Pod.Repo
  alias Pod.CustomPlaylist.{Playlist, PlaylistRecording}
  alias Pod.Stream.LiveStream

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns all playlists for a user with their ready recordings embedded.
  Only recordings with download_url set are included.
  """
  def list_playlists(user_id) do
    ready_recordings_query =
      from pr in PlaylistRecording,
        join: s in assoc(pr, :live_stream),
        where: not is_nil(s.download_url),
        order_by: [asc: pr.inserted_at],
        preload: [live_stream: :creator]

    Playlist
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], asc: p.inserted_at)
    |> preload([p], recordings: ^ready_recordings_query)
    |> Repo.all()
  end

  @doc "Gets a single playlist by ID, returning nil if not owned by user_id."
  def get_playlist(playlist_id, user_id) do
    Repo.get_by(Playlist, id: playlist_id, user_id: user_id)
  end

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  def create_playlist(user_id, name) do
    %Playlist{}
    |> Playlist.changeset(%{user_id: user_id, name: name})
    |> Repo.insert()
  end

  def delete_playlist(playlist_id, user_id) do
    case get_playlist(playlist_id, user_id) do
      nil      -> {:error, :not_found}
      playlist -> Repo.delete(playlist)
    end
  end

  def add_recording(playlist_id, user_id, live_stream_id) do
    case get_playlist(playlist_id, user_id) do
      nil ->
        {:error, :not_found}

      _playlist ->
        case Repo.get_by(LiveStream, id: live_stream_id) do
          nil ->
            {:error, :recording_not_found}

          _ ->
            %PlaylistRecording{}
            |> PlaylistRecording.changeset(%{
              playlist_id:   playlist_id,
              live_stream_id: live_stream_id
            })
            |> Repo.insert()
            |> case do
              {:ok, _}    -> :ok
              {:error, cs} ->
                if has_unique_error?(cs, :custom_playlist_recordings_playlist_id_live_stream_id_index),
                  do: {:error, :already_exists},
                  else: {:error, cs}
            end
        end
    end
  end

  def remove_recording(playlist_id, user_id, live_stream_id) do
    case get_playlist(playlist_id, user_id) do
      nil ->
        {:error, :not_found}

      _playlist ->
        case Repo.get_by(PlaylistRecording,
               playlist_id: playlist_id,
               live_stream_id: live_stream_id
             ) do
          nil    -> {:error, :not_found}
          record -> Repo.delete(record)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp has_unique_error?(changeset, constraint_name) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == constraint_name
    end)
  end
end
