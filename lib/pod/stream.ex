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
  alias Pod.BroadcasterSupervisor.Worker.StreamStartWorker
  alias Pod.BroadcasterSupervisor.Worker.StreamReminderWorker

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

  Automatically generates a unique stream key, constructs the RTMP URL,
  and calculates the invite_deadline as scheduled_start_time - 1 hour.
  If the stream is within 1 hour, invite_deadline is left nil which blocks invites.
  """
  def schedule_stream(attrs) do
    stream_key = generate_stream_key()
    rtmp_url = build_rtmp_url(stream_key)

    attrs
    |> Map.put("stream_key", stream_key)
    |> Map.put("rtmp_url", rtmp_url)
    |> maybe_add_invite_deadline()
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
  # Updating streams
  # ---------------------------------------------------------------------------

  @doc """
  Updates a live stream. Enforces locked fields once the stream is live or ended.
  Locked: scheduled_start_time, age_restriction, record_stream.
  Editable always: title, description, category, tags, is_private, allow_comments.
  """
  def update_live_stream(%LiveStream{status: status} = stream, attrs)
      when status in ["live", "ended"] do
    locked = ["scheduled_start_time", "age_restriction", "record_stream"]
    safe_attrs = Map.drop(attrs, locked ++ Enum.map(locked, &String.to_atom/1))

    stream
    |> LiveStream.changeset(safe_attrs)
    |> Repo.update()
  end

  def update_live_stream(%LiveStream{} = stream, attrs) do
    stream
    |> LiveStream.changeset(attrs)
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

  defp maybe_add_invite_deadline(%{"scheduled_start_time" => scheduled_time} = attrs)
       when not is_nil(scheduled_time) do
    parsed_time =
      case scheduled_time do
        %DateTime{} = dt -> dt
        str -> elem(DateTime.from_iso8601(str), 1)
      end

    one_hour_from_now = DateTime.add(DateTime.utc_now(), 3600, :second)

    if DateTime.compare(parsed_time, one_hour_from_now) == :gt do
      deadline = DateTime.add(parsed_time, -3600, :second) |> DateTime.truncate(:second)
      Map.put(attrs, "invite_deadline", deadline)
    else
      attrs
    end
  end

  defp maybe_add_invite_deadline(attrs), do: attrs


  def schedule_stream_jobs(%{scheduled_start_time: start_time, id: stream_id} = _stream) do
  now        = DateTime.utc_now()
  total_secs = DateTime.diff(start_time, now)

  # Don't schedule if start time is already in the past
  if total_secs <= 0, do: :ok

  base_jobs = [
    {StreamStartWorker,    %{stream_id: stream_id},                    start_time},
    {StreamReminderWorker, %{stream_id: stream_id, threshold: "5_sec"},  at_minus(start_time, 5)},
    {StreamReminderWorker, %{stream_id: stream_id, threshold: "2_min"},  at_minus(start_time, 120)},
    {StreamReminderWorker, %{stream_id: stream_id, threshold: "5_min"},  at_minus(start_time, 300)},
    {StreamReminderWorker, %{stream_id: stream_id, threshold: "10_min"}, at_minus(start_time, 600)},
  ]

  ninety_percent_job =
    if total_secs > 600 do
      fire_at = at_minus(start_time, round(total_secs * 0.1))
      [{StreamReminderWorker, %{stream_id: stream_id, threshold: "90_percent"}, fire_at}]
    else
      []
    end

  (base_jobs ++ ninety_percent_job)
  |> Enum.filter(fn {_, _, run_at} -> DateTime.after?(run_at, now) end)
  |> Enum.each(fn {worker, args, run_at} ->
    args
    |> worker.new(scheduled_at: run_at, queue: :streams)
    |> Oban.insert!()
  end)

  :ok
end

defp at_minus(datetime, seconds) do
  DateTime.add(datetime, -seconds, :second)
end
end
