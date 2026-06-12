defmodule PodWeb.StreamController do
  use PodWeb, :controller

  alias Pod.Stream
  alias Pod.Creators
  alias Pod.ListeningHistory
  alias Pod.Accounts.Guardian

  action_fallback PodWeb.FallbackController

  # ---------------------------------------------------------------------------
  # Schedule a new stream
  # POST /api/streams
  # ---------------------------------------------------------------------------

  def create(conn, params = %{"user_id" => user_id}) do
    with creator when not is_nil(creator) <- Creators.get_creator_by_user(user_id),
         {:ok, stream} <-
           Stream.schedule_stream(
             params
             |> Map.put("creator_id", creator.id)
             |> Map.put("channel_id", creator.channel_id)
           ) do
      Stream.schedule_stream_jobs(stream)
      conn
      |> put_status(:created)
      |> json(%{
        message: "Stream scheduled successfully",
        stream: format_stream(%{stream | creator: creator})
      })
    else
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Creator profile not found. Set up your creator profile first."})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  # ---------------------------------------------------------------------------
  # Get a single stream
  # GET /api/streams/:id
  # ---------------------------------------------------------------------------

  def show(conn, %{"id" => id}) do
    case Stream.get_stream(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Stream not found"})

      stream ->
        conn
        |> put_status(:ok)
        |> json(%{stream: format_stream(stream)})
    end
  end
  # ---------------------------------------------------------------------------
  # List all currently live public streams
  # GET /api/streams/live
  # ---------------------------------------------------------------------------

  def live(conn, _params) do
    streams = Stream.list_live_streams()

    conn
    |> put_status(:ok)
    |> json(%{streams: Enum.map(streams, &format_stream/1)})
  end

  # ---------------------------------------------------------------------------
  # List recorded streams available as replays
  # GET /api/streams/recorded
  # ---------------------------------------------------------------------------

  def recorded(conn, _params) do
    streams = Stream.list_recorded_streams()

    conn
    |> put_status(:ok)
    |> json(%{streams: Enum.map(streams, &format_stream/1)})
  end

  # ---------------------------------------------------------------------------
  # Get all streams for the authenticated creator
  # GET /api/streams/my
  # ---------------------------------------------------------------------------

  def my_streams(conn, _params) do
    user_id = get_user_id(conn)

    streams =
      case Creators.get_creator_by_user(user_id) do
        nil     -> []
        creator -> Stream.list_streams_for_creator(creator.id)
      end

    conn
    |> put_status(:ok)
    |> json(%{streams: Enum.map(streams, &format_stream/1)})
  end

  # ---------------------------------------------------------------------------
  # End a stream manually via API
  # PUT /api/streams/:id/end
  # ---------------------------------------------------------------------------

  def end_stream(conn, %{"id" => id}) do
    user_id = get_user_id(conn)

    with stream when not is_nil(stream) <- Stream.get_stream(id),
         creator when not is_nil(creator) <- Creators.get_creator_by_user(user_id),
         true <- creator.id == stream.creator_id,
         {:ok, updated} <- Stream.end_stream(stream) do
      conn
      |> put_status(:ok)
      |> json(%{message: "Stream ended", stream: format_stream(%{updated | creator: stream.creator})})
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Stream not found"})

      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You are not the creator of this stream"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  # ---------------------------------------------------------------------------
  # Get stream key for a scheduled stream (creator only)
  # GET /api/streams/:id/stream_key
  # ---------------------------------------------------------------------------

  def stream_key(conn, %{"id" => id}) do
    user_id = get_user_id(conn)

    with stream when not is_nil(stream) <- Stream.get_stream(id),
         creator when not is_nil(creator) <- Creators.get_creator_by_user(user_id),
         true <- creator.id == stream.creator_id do
      conn
      |> put_status(:ok)
      |> json(%{
        stream_key: stream.stream_key,
        rtmp_url: stream.rtmp_url
      })
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Stream not found"})

      false ->
        conn |> put_status(:forbidden) |> json(%{error: "Unauthorized"})
    end
  end

  # ---------------------------------------------------------------------------
  # Create a manually-uploaded recording (no RTMP)
  # POST /api/recordings
  #
  # Body: { title, description, thumbnail_url, master_url, duration_seconds, category }
  # master_url is the audio_url returned from POST /api/uploads/audio_presign
  # ---------------------------------------------------------------------------

  def create_recording(conn, params) do
    user_id = get_user_id(conn)

    case Creators.get_creator_by_user(user_id) do
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Creator profile not found. Set up your creator profile first."})

      creator ->
        attrs = %{
          "title"            => Map.get(params, "title"),
          "description"      => Map.get(params, "description"),
          "category"         => Map.get(params, "category"),
          "thumbnail"        => Map.get(params, "thumbnail_url"),
          "archive_path"     => Map.get(params, "master_url"),
          "duration_seconds" => Map.get(params, "duration_seconds", 0),
          "tags"             => Map.get(params, "tags", []),
          "language"         => Map.get(params, "language", "en"),
          "is_private"       => Map.get(params, "is_private", false),
          "creator_id"       => creator.id,
          "channel_id"       => creator.channel_id
        }

        case Stream.create_recording(attrs) do
          {:ok, recording} ->
            conn
            |> put_status(:created)
            |> json(%{recording: format_stream(%{recording | creator: creator})})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_errors(changeset)})
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Record listening progress
  # POST /api/streams/:stream_id/progress
  #
  # Called periodically by the mobile player (e.g. every 15 seconds).
  # Creates or updates a single row per user per stream.
  #
  # Params:
  #   progress_seconds  — integer, current playback position
  #   completed         — boolean, true when the episode finishes
  # ---------------------------------------------------------------------------

  def update_progress(conn, %{"stream_id" => stream_id} = params) do
    user_id          = get_user_id(conn)
    progress_seconds = Map.get(params, "progress_seconds", 0)
    completed        = Map.get(params, "completed", false)

    case ListeningHistory.record_progress(user_id, stream_id, progress_seconds, completed) do
      {:ok, history} ->
        conn
        |> put_status(:ok)
        |> json(%{
          progress_seconds: history.progress_seconds,
          completed:        history.completed
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_user_id(conn) do
    Guardian.Plug.current_resource(conn).id
  end

  # ---------------------------------------------------------------------------
  # Public format — used by FeedChannel and StreamChannel too
  # Preloads creator so we can include name, avatar, channel_id
  # ---------------------------------------------------------------------------

  def format_stream_public(stream) do
    storage = Application.get_env(:pod, :storage, [])
    base_url = Keyword.get(storage, :base_url, "")

    # Ended recordings are served as a packaged MP3 (download_url — set once FFmpeg
    # finishes). Live/scheduled streams use the HLS manifest for real-time playback.
    master_url =
      if stream.status == "ended" do
        stream.download_url
      else
        case Keyword.get(storage, :adapter) do
          :s3    -> "#{base_url}/broadcasters/#{stream.id}/master.m3u8"
          _local -> "#{base_url}/#{stream.id}/master.m3u8"
        end
      end

    creator = case stream.creator do
      %Ecto.Association.NotLoaded{} -> nil
      c -> c
    end

    %{
      id:                   stream.id,
      title:                stream.title,
      description:          stream.description,
      category:             stream.category,
      status:               stream.status,
      is_private:           stream.is_private,
      allow_comments:       stream.allow_comments,
      record_stream:        stream.record_stream,
      audio_quality:        stream.audio_quality,
      tags:                 stream.tags,
      thumbnail:            stream.thumbnail,
      language:             stream.language,
      age_restriction:      stream.age_restriction,
      viewer_count:         stream.viewer_count,
      peak_viewers:         stream.peak_viewers,
      scheduled_start_time: stream.scheduled_start_time,
      actual_start_time:    stream.actual_start_time,
      end_time:             stream.end_time,
      creator_id:           stream.creator_id,
      channel_id:           stream.channel_id,
      creator_name:         creator && creator.name,
      creator_avatar:       creator && creator.avatar,
      duration_seconds:     stream.duration_seconds,
      segment_count:        stream.segment_count,
      master_url:           master_url,
      download_url:         stream.download_url
    }
  end

  defp format_stream(stream), do: format_stream_public(stream)

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
