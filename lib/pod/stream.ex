defmodule Pod.Stream do
  @moduledoc """
  The Stream context.

  Handles all business logic around live streams — scheduling, starting,
  ending, authentication via stream key, and stats updates.

  This is the boundary between your web/API layer and the database for
  anything stream related. The RTMPServer, Season, and Segmenter all call
  into this context rather than touching Repo directly.
  """

  import Ecto.Query
  alias Pod.Repo
  alias Pod.Stream.LiveStream

  # ---------------------------------------------------------------------------
  # Stream key authentication
  # Called by RTMPServer when a broadcaster connects
  # ---------------------------------------------------------------------------

  @doc """
  Looks up a LiveStream by its stream key.

  Returns `{:ok, live_stream}` if found and status is "scheduled".
  Returns `{:error, :not_found}` if no stream matches the key.
  Returns `{:error, :not_scheduled}` if the stream exists but is already
  live or ended — prevents someone reusing an old stream key.
  """
  def authenticate_stream(stream_key) when is_binary(stream_key) do
    case Repo.get_by(LiveStream, stream_key: stream_key) do
      nil ->
        {:error, :not_found}

      %LiveStream{status: "scheduled"} = stream ->
        {:ok, stream}

      %LiveStream{status: status} ->
        {:error, {:not_scheduled, status}}
    end
  end

  # ---------------------------------------------------------------------------
  # Scheduling a stream
  # Called when a creator creates a new scheduled broadcast
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new scheduled live stream for a creator.

  Automatically generates a unique stream key and constructs the RTMP URL.
  The stream key is what the broadcaster puts into OBS or their client to
  authenticate when they connect.
  """
  def schedule_stream(attrs) do
    stream_key = generate_stream_key()
    rtmp_url = build_rtmp_url(stream_key)

    attrs
    |> Map.put("stream_key", stream_key)
    |> Map.put("rtmp_url", rtmp_url)
    |> then(&LiveStream.changeset(%LiveStream{}, &1))
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Stream lifecycle
  # Called by Season as the broadcast progresses
  # ---------------------------------------------------------------------------

  @doc """
  Marks a stream as live and records the actual start time.

  Called by Season the moment the first audio segment arrives — this is the
  real confirmation that the broadcaster is actually streaming, not just
  connected.
  """
  def start_stream(%LiveStream{} = stream) do
    stream
    |> LiveStream.start_stream_changeset(%{
      status: "live",
      actual_start_time: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  @doc """
  Marks a stream as ended and records final stats.

  Called by Season's terminate/2 when the broadcaster disconnects.
  The Segmenter also calls this after finalising the archive playlist.

  attrs can include:
    - end_time
    - total_viewers
    - peak_viewers
    - avg_watch_time
    - engagement_rate
    - segment_count  (once you add this field to the schema)
    - archive_path   (once you add this field to the schema)
  """
  def end_stream(%LiveStream{} = stream, attrs \\ %{}) do
    final_attrs =
      attrs
      |> Map.put("status", "ended")
      |> Map.put("end_time", DateTime.utc_now() |> DateTime.truncate(:second))

    stream
    |> LiveStream.end_stream_changeset(final_attrs)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Fetching streams
  # ---------------------------------------------------------------------------

  @doc """
  Gets a single stream by ID.
  Returns nil if not found.
  """
  def get_stream(id), do: Repo.get(LiveStream, id)

  @doc """
  Gets a single stream by ID, raising if not found.
  """
  def get_stream!(id), do: Repo.get!(LiveStream, id)

  @doc """
  Gets all currently live streams.
  Used for discovery — showing listeners what is streaming right now.
  """
  def list_live_streams do
    LiveStream
    |> where([s], s.status == "live")
    |> where([s], s.is_private == false)
    |> order_by([s], desc: s.actual_start_time)
    |> Repo.all()
  end

  @doc """
  Gets all streams for a specific creator — their broadcast history.
  """
  def list_streams_for_creator(creator_id) do
    LiveStream
    |> where([s], s.creator_id == ^creator_id)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets all ended streams that were recorded — available as replays/podcasts.
  """
  def list_recorded_streams do
    LiveStream
    |> where([s], s.status == "ended")
    |> where([s], s.record_stream == true)
    |> where([s], s.is_private == false)
    |> order_by([s], desc: s.end_time)
    |> Repo.all()
  end

  @doc """
  Updates viewer count for a live stream.
  Called by your Phoenix Channel presence system as listeners join/leave.
  """
  def update_viewer_count(%LiveStream{} = stream, count) do
    peak = max(stream.peak_viewers, count)

    stream
    |> LiveStream.changeset(%{
      "viewer_count" => count,
      "peak_viewers" => peak,
      "total_viewers" => stream.total_viewers + max(0, count - stream.viewer_count)
    })
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Generates a cryptographically random stream key.
  # Format: 32 random hex characters — long enough to be unguessable,
  # short enough to be manageable.
  defp generate_stream_key do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp build_rtmp_url(stream_key) do
    base = Application.get_env(:pod, :rtmp_base_url, "rtmp://localhost:1935/live")
    "#{base}/#{stream_key}"
  end
end
