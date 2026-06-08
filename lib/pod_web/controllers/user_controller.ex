defmodule PodWeb.UserController do
  use PodWeb, :controller

  alias Pod.Playlists
  alias Pod.Follows
  alias Pod.Playlist.UserPlaylist
  alias Pod.Accounts.Guardian

  action_fallback PodWeb.FallbackController

  # GET /api/users/me/following
  def following(conn, _params) do
    user_id = get_user_id(conn)
    {creators, live_ids} = Follows.list_followed_with_live(user_id)

    conn
    |> put_status(:ok)
    |> json(%{creators: Enum.map(creators, &format_creator(&1, live_ids))})
  end

  # GET /api/users/me/:playlist
  def playlist(conn, %{"playlist" => type}) do
    if Playlists.valid_type?(type) do
      user_id    = get_user_id(conn)
      recordings = Playlists.list_playlist(user_id, type)

      conn
      |> put_status(:ok)
      |> json(%{recordings: Enum.map(recordings, &format_recording/1)})
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Invalid playlist. Must be one of: #{Enum.join(UserPlaylist.valid_types(), ", ")}"})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_user_id(conn), do: Guardian.Plug.current_resource(conn).id

  defp format_recording(stream) do
    storage  = Application.get_env(:pod, :storage, [])
    base_url = Keyword.get(storage, :base_url, "")

    master_url =
      case Keyword.get(storage, :adapter) do
        :s3    -> "#{base_url}/broadcasters/#{stream.id}/master.m3u8"
        _local -> "#{base_url}/#{stream.id}/master.m3u8"
      end

    creator =
      case stream.creator do
        %Ecto.Association.NotLoaded{} -> nil
        c -> c
      end

    %{
      id:                stream.id,
      title:             stream.title,
      description:       stream.description,
      category:          stream.category,
      tags:              stream.tags,
      thumbnail:         stream.thumbnail,
      language:          stream.language,
      audio_quality:     stream.audio_quality,
      duration_seconds:  stream.duration_seconds,
      segment_count:     stream.segment_count,
      actual_start_time: stream.actual_start_time,
      end_time:          stream.end_time,
      creator_id:        stream.creator_id,
      creator_name:      creator && creator.name,
      creator_avatar:    creator && creator.avatar,
      peak_viewers:      stream.peak_viewers,
      master_url:        master_url
    }
  end

  defp format_creator(creator, live_ids) do
    %{
      id:             creator.id,
      name:           creator.name,
      thumbnail_url:  creator.avatar,
      follower_count: creator.follower_count,
      is_live:        MapSet.member?(live_ids, creator.id)
    }
  end
end
