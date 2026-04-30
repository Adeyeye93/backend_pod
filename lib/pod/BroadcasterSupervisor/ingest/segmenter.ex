defmodule Pod.BroadcasterSupervisor.Ingest.Segmenter do
  @moduledoc """
  One GenServer per active broadcaster session.

  Receives transcoded audio segments from Season and is responsible for:

    1. Writing segment files — one per bitrate (128k, 192k, 320k) per flush
    2. Maintaining the live rolling HLS playlist — last 6 segments so
       listeners always have a valid window to join from
    3. Writing the master playlist once on first segment — points to the
       three bitrate playlists
    4. Uploading everything to S3 in production — local disk in dev
    5. Finalising the archive on broadcast end — adds #EXT-X-ENDLIST tag
       so the full recording is playable as a podcast/replay
    6. Updating the LiveStream record in the database when the broadcast ends

  ## Storage structure

  Local (dev):
    priv/segments/{live_stream_id}/
      master.m3u8
      128k.m3u8
      192k.m3u8
      320k.m3u8
      128k/segment_001.aac
      192k/segment_001.aac
      320k/segment_001.aac

  S3 (production):
    broadcasters/{live_stream_id}/
      master.m3u8
      128k.m3u8
      192k.m3u8
      320k.m3u8
      128k/segment_001.aac
      192k/segment_001.aac
      320k/segment_001.aac

  ## Segment naming

  Segments are zero-padded 6-digit numbers: segment_000001.aac
  This ensures correct lexicographic ordering if segments are ever
  listed from a directory or S3 prefix.

  ## HLS playlist rolling window

  The live playlist keeps the last 6 segments — roughly 18 seconds of
  audio at 3 seconds per segment. This gives a listener's player enough
  buffer to join and start playing without the playlist growing forever.
  Old segments are removed from the playlist but kept in storage for
  the archive.
  """

  use GenServer
  require Logger

  alias Pod.Stream
  alias PodWeb.StreamChannel

  @bitrates [128, 192, 320]
  @segment_duration 3
  @playlist_window 6

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Called from Season.handle_info({:transcoded, {:ok, segments}}).

  segments = %{128 => <<binary>>, 192 => <<binary>>, 320 => <<binary>>}
  """
  def write_segment(pid, live_stream_id, segments) do
    GenServer.cast(pid, {:write_segment, live_stream_id, segments})
  end

  @doc """
  Called from Season.terminate/2 when the broadcaster disconnects.
  Finalises the archive playlist and updates the database record.
  """
  def finalise(pid) do
    GenServer.cast(pid, :finalise)
  end

  # ---------------------------------------------------------------------------
  # Init
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    session_id = opts[:session_id]
    storage = storage_config()

    # Register so Season can look us up by session_id
    Registry.register(Pod.SessionRegistry, {session_id, :segmenter}, nil)

    Logger.info("[Segmenter] Starting — session: #{session_id}, adapter: #{storage.adapter}")

    state = %{
      live_stream_id: nil,
      session_id: session_id,
      segment_count: 0,
      playlist_window: [],
      all_segments: [],
      master_written: false,
      storage: storage,
      started_at: DateTime.utc_now()
    }

    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # Write segment
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:write_segment, live_stream_id, segments}, state) do
    # live_stream_id arrives here on first segment — set it and create dirs
    state =
      if is_nil(state.live_stream_id) do
        Logger.info("[Segmenter] First segment — live_stream_id: #{live_stream_id}")

        if state.storage.adapter == :local do
          setup_local_dirs(live_stream_id, state.storage.local_path)
        end

        %{state | live_stream_id: live_stream_id}
      else
        state
      end

    segment_number = state.segment_count + 1
    segment_name = segment_filename(segment_number)

    Logger.info("[Segmenter] Writing segment #{segment_number} for stream #{state.live_stream_id}")

    # Write all three bitrate files
    Enum.each(@bitrates, fn kbps ->
      case Map.get(segments, kbps) do
        nil ->
          Logger.warning("[Segmenter] Missing #{kbps}k segment for segment #{segment_number}")

        data ->
          path = segment_path(state.live_stream_id, kbps, segment_name, state.storage)
          write_file(path, data, state.storage)
      end
    end)

    # Write master playlist on the very first segment only
    state =
      if not state.master_written do
        write_master_playlist(state)
        %{state | master_written: true}
      else
        state
      end

    # Update rolling window — add new, drop oldest if over limit
    new_entry = %{name: segment_name, duration: @segment_duration}

    new_window =
      (state.playlist_window ++ [new_entry])
      |> Enum.take(-@playlist_window)

    all_segments = state.all_segments ++ [new_entry]

    # Update the live playlists for all three bitrates
    Enum.each(@bitrates, fn kbps ->
      write_live_playlist(state.live_stream_id, kbps, new_window, segment_number, state.storage)
    end)

    # Notify all listeners via Phoenix Channel that a new segment is ready
    segment_urls = build_segment_urls(state.live_stream_id, segment_name, state.storage)
    StreamChannel.notify_segment_ready(state.live_stream_id, segment_number, segment_urls)

    new_state = %{state |
      segment_count: segment_number,
      playlist_window: new_window,
      all_segments: all_segments
    }

    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Finalise — called when broadcast ends
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast(:finalise, %{live_stream_id: nil} = state) do
    # Broadcaster disconnected before any segments were written —
    # nothing to finalise, DB update is handled by Season.terminate directly
    Logger.info("[Segmenter] Finalise called with no segments — skipping")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:finalise, state) do
    Logger.info("[Segmenter] Finalising archive for stream #{state.live_stream_id}")

    Enum.each(@bitrates, fn kbps ->
      write_archive_playlist(state.live_stream_id, kbps, state.all_segments, state.storage)
    end)

    duration_seconds = state.segment_count * @segment_duration
    archive_path = master_playlist_path(state.live_stream_id, state.storage)

    case Stream.get_stream(state.live_stream_id) do
      nil ->
        Logger.warning("[Segmenter] Could not find stream #{state.live_stream_id} to finalise")

      live_stream ->
        Stream.end_stream(live_stream, %{
          "segment_count"    => state.segment_count,
          "archive_path"     => archive_path,
          "duration_seconds" => duration_seconds
        })
        PodWeb.FeedChannel.stream_ended(state.live_stream_id) # Broadcast to feed channel so listeners see it immediately

        Logger.info("[Segmenter] ✓ Archive finalised — #{state.segment_count} segments, " <>
          "#{duration_seconds}s, path: #{archive_path}")
    end

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private — playlist builders
  # ---------------------------------------------------------------------------

  defp write_master_playlist(state) do
    content = """
    #EXTM3U
    #EXT-X-VERSION:3

    #EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"
    128k.m3u8

    #EXT-X-STREAM-INF:BANDWIDTH=192000,CODECS="mp4a.40.2"
    192k.m3u8

    #EXT-X-STREAM-INF:BANDWIDTH=320000,CODECS="mp4a.40.2"
    320k.m3u8
    """

    path = master_playlist_path(state.live_stream_id, state.storage)
    write_file(path, content, state.storage)
    Logger.info("[Segmenter] ✓ Master playlist written")
  end

  defp write_live_playlist(live_stream_id, kbps, window, media_sequence, storage) do
    # media_sequence tells the player where in the overall stream this
    # window starts. It increments as old segments roll off the window.
    sequence_start = max(0, media_sequence - @playlist_window)

    segments_content =
      Enum.map_join(window, "\n", fn %{name: name, duration: duration} ->
        "#EXTINF:#{duration}.0,\n#{name}"
      end)

    content = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:#{@segment_duration}
    #EXT-X-MEDIA-SEQUENCE:#{sequence_start}

    #{segments_content}
    """

    path = playlist_path(live_stream_id, kbps, storage)
    write_file(path, content, storage)
  end

  defp write_archive_playlist(live_stream_id, kbps, all_segments, storage) do
    segments_content =
      Enum.map_join(all_segments, "\n", fn %{name: name, duration: duration} ->
        "#EXTINF:#{duration}.0,\n#{name}"
      end)

    # #EXT-X-ENDLIST marks this as a complete VOD recording
    # Without it, players treat it as a live stream and keep polling
    content = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:#{@segment_duration}
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-PLAYLIST-TYPE:VOD

    #{segments_content}
    #EXT-X-ENDLIST
    """

    path = playlist_path(live_stream_id, kbps, storage)
    write_file(path, content, storage)
    Logger.info("[Segmenter] ✓ Archive playlist written for #{kbps}k — #{length(all_segments)} segments")
  end

  # ---------------------------------------------------------------------------
  # Private — storage abstraction
  # Local in dev, S3 in prod — same interface, different backends
  # ---------------------------------------------------------------------------

  defp write_file(path, data, %{adapter: :local}) do
    path |> Path.dirname() |> File.mkdir_p!()

    case File.write(path, data) do
      :ok ->
        Logger.debug("[Segmenter] Written locally: #{path}")

      {:error, reason} ->
        Logger.error("[Segmenter] Failed to write #{path}: #{inspect(reason)}")
    end
  end

  defp write_file(path, data, %{adapter: :s3, bucket: bucket}) do
    data_binary = if is_binary(data), do: data, else: IO.iodata_to_binary(data)

    content_type = if String.ends_with?(path, ".m3u8"),
      do: "application/vnd.apple.mpegurl",
      else: "audio/aac"

    request =
      ExAws.S3.put_object(bucket, path, data_binary,
        content_type: content_type
      )

    case ExAws.request(request) do
      {:ok, _} ->
        Logger.debug("[Segmenter] Uploaded to S3: s3://#{bucket}/#{path}")

      {:error, reason} ->
        Logger.error("[Segmenter] S3 upload failed for #{path}: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Private — path helpers
  # ---------------------------------------------------------------------------

  defp segment_filename(number) do
    "segment_#{String.pad_leading(Integer.to_string(number), 6, "0")}.aac"
  end

  defp segment_path(live_stream_id, kbps, filename, storage) do
    base_path(live_stream_id, storage) <> "/#{kbps}k/#{filename}"
  end

  defp playlist_path(live_stream_id, kbps, storage) do
    base_path(live_stream_id, storage) <> "/#{kbps}k.m3u8"
  end

  defp master_playlist_path(live_stream_id, %{adapter: :local, local_path: local_path}) do
    "#{local_path}/#{live_stream_id}/master.m3u8"
  end

  defp master_playlist_path(live_stream_id, %{adapter: :s3}) do
    "broadcasters/#{live_stream_id}/master.m3u8"
  end

  defp base_path(live_stream_id, %{adapter: :local, local_path: local_path}) do
    "#{local_path}/#{live_stream_id}"
  end

  defp base_path(live_stream_id, %{adapter: :s3}) do
    "broadcasters/#{live_stream_id}"
  end

  defp setup_local_dirs(live_stream_id, local_path) do
    Enum.each(@bitrates, fn kbps ->
      path = "#{local_path}/#{live_stream_id}/#{kbps}k"
      File.mkdir_p!(path)
    end)

    Logger.debug("[Segmenter] Local directories created at #{local_path}/#{live_stream_id}")
  end

  defp build_segment_urls(live_stream_id, segment_name, storage) do
    Enum.into(@bitrates, %{}, fn kbps ->
      url =
        case storage.adapter do
          :local ->
            # In dev, Phoenix serves files from priv/static
            # You will need to symlink or serve priv/segments via Plug.Static
            "/segments/#{live_stream_id}/#{kbps}k/#{segment_name}"

          :s3 ->
            bucket = storage.bucket
            region = Application.get_env(:ex_aws, :region, "us-east-1")
            "https://#{bucket}.s3.#{region}.amazonaws.com/broadcasters/#{live_stream_id}/#{kbps}k/#{segment_name}"
        end

      {kbps, url}
    end)
  end

  defp storage_config do
    config = Application.get_env(:pod, :storage, adapter: :local, local_path: "priv/segments")

    %{
      adapter: config[:adapter] || :local,
      local_path: config[:local_path] || "priv/segments",
      bucket: config[:bucket]
    }
  end
end
