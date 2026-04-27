defmodule PodWeb.StreamController do
  use PodWeb, :controller

  alias Pod.Stream
  alias Pod.Creators
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
        stream: format_stream(stream)
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

    case Creators.get_creator_by_user(user_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Creator profile not found"})

      creator ->
        streams = Stream.list_streams_for_creator(creator.id)

        conn
        |> put_status(:ok)
        |> json(%{streams: Enum.map(streams, &format_stream/1)})
    end
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
      |> json(%{message: "Stream ended", stream: format_stream(updated)})
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
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_user_id(conn) do
    Guardian.Plug.current_resource(conn).id
  end

  defp format_stream(stream) do
    %{
      id: stream.id,
      title: stream.title,
      description: stream.description,
      category: stream.category,
      status: stream.status,
      is_private: stream.is_private,
      allow_comments: stream.allow_comments,
      record_stream: stream.record_stream,
      audio_quality: stream.audio_quality,
      tags: stream.tags,
      thumbnail: stream.thumbnail,
      language: stream.language,
      age_restriction: stream.age_restriction,
      viewer_count: stream.viewer_count,
      peak_viewers: stream.peak_viewers,
      scheduled_start_time: stream.scheduled_start_time,
      actual_start_time: stream.actual_start_time,
      end_time: stream.end_time,
      creator_id: stream.creator_id
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
