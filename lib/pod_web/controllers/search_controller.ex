defmodule PodWeb.SearchController do
  use PodWeb, :controller

  alias Pod.Search

  action_fallback PodWeb.FallbackController

  # GET /api/search?q=<query>
  def search(conn, params) do
    q = Map.get(params, "q", "") |> String.trim()

    if q == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "query is required"})
    else
      [recordings, {creators, live_ids}] =
        [
          Task.async(fn -> Search.search_recordings(q) end),
          Task.async(fn -> Search.search_creators(q) end)
        ]
        |> Task.await_many(5_000)

      conn
      |> put_status(:ok)
      |> json(%{
        recordings: Enum.map(recordings, &format_recording/1),
        channels:   Enum.map(creators, &format_creator(&1, live_ids))
      })
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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
