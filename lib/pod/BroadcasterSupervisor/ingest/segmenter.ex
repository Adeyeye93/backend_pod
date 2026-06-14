defmodule Pod.BroadcasterSupervisor.Ingest.Segmenter do
  @moduledoc """
  One GenServer per active broadcaster session.

  Receives transcoded audio dispatches from Season and accumulates them into
  proper HLS segments before writing to storage.

  ## Why accumulation is necessary

  The AudioBuffer flushes every 3 AAC frames. Each AAC frame = 1024 samples,
  so at 48 000 Hz each dispatch carries only ~64 ms of audio. Writing one
  segment file per dispatch would produce #EXTINF:3.0 entries in the playlist
  that claim 3 s of audio but actually contain 64 ms — causing FFmpeg to
  produce ~20 s of audio from a 12-minute stream.

  Instead, dispatches are accumulated in memory until enough frames exist for
  a real target-duration segment, then flushed as a single file. The partial
  segment at the end of a broadcast is flushed on finalise.

  ## Timing constants

    - @samples_per_aac_frame  1024          (AAC standard)
    - @default_sample_rate    48 000 Hz     (from AAC config, sample_rate_index: 3)
    - @frames_per_segment     141 frames    (≈ 3.008 s — 47 full dispatches of 3)
    - @target_duration        4             (#EXT-X-TARGETDURATION, ceil of 3.008)

  The Transcoder passes the actual frame count per dispatch (normally 3, but can
  be 1–2 from Season's flush_timeout on a partial buffer). accumulated_frames
  tracks the real count so #EXTINF values match actual audio content.

  ## Storage structure

  Local (dev):
    priv/segments/{live_stream_id}/
      master.m3u8
      128k.m3u8 / 192k.m3u8 / 320k.m3u8
      128k/segment_000001.aac  …

  S3 (production):
    broadcasters/{live_stream_id}/
      master.m3u8
      128k.m3u8 / 192k.m3u8 / 320k.m3u8
      128k/segment_000001.aac  …

  ## HLS rolling window

  The live playlist keeps the last 6 complete segments (~18 s) so listeners
  always have a valid buffer to join from.
  """

  use GenServer
  require Logger

  alias Pod.Stream
  alias PodWeb.StreamChannel

  @bitrates [128, 192, 320]

  # AAC audio timing
  @samples_per_aac_frame 1024
  @default_sample_rate   48_000

  # Target HLS segment duration
  @segment_duration 3               # seconds (used as target and for EXTINF rounding)

  # Frames to accumulate before flushing one segment file.
  # round(3 * 48000 / 1024) = round(141.17) = 141 = 47 dispatches exactly.
  @frames_per_segment round(@segment_duration * @default_sample_rate / @samples_per_aac_frame)

  # EXT-X-TARGETDURATION must be >= max EXTINF value (ceil of 3.008 = 4)
  @target_duration ceil(@frames_per_segment * @samples_per_aac_frame / @default_sample_rate)

  @playlist_window 6

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Called from Season.handle_info({:transcoded, {:ok, frame_count, segments}}).

  frame_count — actual AAC frames in this dispatch (1–3; may be < 3 from flush_timeout)
  segments    — %{128 => <<binary>>, 192 => <<binary>>, 320 => <<binary>>}
  """
  def write_segment(pid, live_stream_id, frame_count, segments) do
    GenServer.cast(pid, {:write_segment, live_stream_id, frame_count, segments})
  end

  @doc """
  Called from Season.terminate/2 when the broadcaster disconnects.
  Flushes any buffered audio, finalises the archive playlist, and updates
  the LiveStream DB record.
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
    storage    = storage_config()

    Registry.register(Pod.SessionRegistry, {session_id, :segmenter}, nil)

    Logger.info("[Segmenter] Starting — session: #{session_id}, adapter: #{storage.adapter}")

    state = %{
      live_stream_id:      nil,
      session_id:          session_id,
      segment_count:       0,        # segment files written (used for naming)
      playlist_window:     [],
      all_segments:        [],
      master_written:      false,
      storage:             storage,
      started_at:          DateTime.utc_now(),
      # Accumulation buffer — holds binary data across dispatches until a
      # full target-duration segment is ready to write.
      accumulator:         %{},      # %{kbps => binary}
      accumulated_frames:  0,        # AAC frames in accumulator (resets on flush)
      total_received:      0         # cumulative frames received (never resets — used for diagnostics)
    }

    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # Receive a transcoded dispatch — accumulate, flush when full
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:write_segment, live_stream_id, frame_count, segments}, state) do
    state =
      if is_nil(state.live_stream_id) do
        Logger.info("[Segmenter] First dispatch — live_stream_id: #{live_stream_id}")

        if state.storage.adapter == :local do
          setup_local_dirs(live_stream_id, state.storage.local_path)
        end

        %{state | live_stream_id: live_stream_id}
      else
        state
      end

    # Write master playlist on the very first dispatch
    state =
      if not state.master_written do
        write_master_playlist(state)
        %{state | master_written: true}
      else
        state
      end

    # Append this dispatch's binary to the per-bitrate accumulator
    new_accumulator =
      Enum.reduce(@bitrates, state.accumulator, fn kbps, acc ->
        case Map.get(segments, kbps) do
          nil ->
            Logger.warning("[Segmenter] Missing #{kbps}k data in dispatch for #{state.live_stream_id}")
            acc

          data ->
            Map.update(acc, kbps, data, &(&1 <> data))
        end
      end)

    new_accumulated_frames = state.accumulated_frames + frame_count
    new_total_received     = state.total_received + frame_count

    Logger.debug("[Segmenter] Dispatch +#{frame_count} frames | " <>
      "buffer: #{new_accumulated_frames}/#{@frames_per_segment} | " <>
      "total_received: #{new_total_received}")

    state = %{state |
      accumulator:        new_accumulator,
      accumulated_frames: new_accumulated_frames,
      total_received:     new_total_received
    }

    # Flush a full segment when we have enough frames
    state =
      if new_accumulated_frames >= @frames_per_segment do
        flush_segment(state)
      else
        state
      end

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Finalise — called when broadcast ends
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast(:finalise, %{live_stream_id: nil} = state) do
    Logger.info("[Segmenter] Finalise called with no audio — skipping")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:finalise, state) do
    Logger.info("[Segmenter] Finalising archive for stream #{state.live_stream_id} — " <>
      "#{state.segment_count} segments written, #{state.accumulated_frames} frames in partial buffer")

    # Flush any partial segment remaining in the accumulator
    state =
      if state.accumulated_frames > 0 and map_size(state.accumulator) > 0 do
        Logger.info("[Segmenter] Flushing partial final segment — #{state.accumulated_frames} frames")
        flush_segment(state)
      else
        state
      end

    Logger.info("[Segmenter] Archive will include #{length(state.all_segments)} segments total")

    Enum.each(@bitrates, fn kbps ->
      write_archive_playlist(state.live_stream_id, kbps, state.all_segments, state.storage)
    end)

    duration_seconds =
      state.all_segments
      |> Enum.reduce(0.0, fn %{duration: d}, acc -> acc + d end)
      |> round()

    archive_path = master_playlist_path(state.live_stream_id, state.storage)

    case Stream.get_stream(state.live_stream_id) do
      nil ->
        Logger.warning("[Segmenter] Stream #{state.live_stream_id} not found for finalise")

      live_stream ->
        case Stream.end_stream(live_stream, %{
          "segment_count"    => state.segment_count,
          "archive_path"     => archive_path,
          "duration_seconds" => duration_seconds
        }) do
          {:ok, _} ->
            Logger.info("[Segmenter] ✓ Archive finalised — #{state.segment_count} segments, " <>
              "#{duration_seconds}s, path: #{archive_path}")

          {:error, reason} ->
            Logger.error("[Segmenter] end_stream failed — stream: #{state.live_stream_id}, " <>
              "reason: #{inspect(reason)}")
        end

        PodWeb.FeedChannel.stream_ended(state.live_stream_id)
        StreamChannel.notify_stream_ended(state.live_stream_id)
    end

    frames_written =
      state.all_segments
      |> Enum.reduce(0.0, fn %{duration: d}, acc -> acc + d * @default_sample_rate / @samples_per_aac_frame end)
      |> round()

    Logger.info("[Segmenter] ACCOUNTING — total_received: #{state.total_received} frames | " <>
      "frames_written: #{frames_written} frames across #{length(state.all_segments)} segments | " <>
      "delta (lost): #{state.total_received - frames_written} frames " <>
      "(#{Float.round((state.total_received - frames_written) * @samples_per_aac_frame / @default_sample_rate, 1)}s)")

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private — flush accumulated audio as one segment file
  # ---------------------------------------------------------------------------

  defp flush_segment(state) do
    segment_number = state.segment_count + 1
    segment_name   = segment_filename(segment_number)

    # Actual duration from frame count — correct value for #EXTINF
    duration = Float.round(
      state.accumulated_frames * @samples_per_aac_frame / @default_sample_rate,
      3
    )

    Logger.info("[Segmenter] Writing segment #{segment_number} — #{state.accumulated_frames} frames → #{duration}s " <>
      "(total_received so far: #{state.total_received})")

    Enum.each(@bitrates, fn kbps ->
      case Map.get(state.accumulator, kbps) do
        nil ->
          Logger.warning("[Segmenter] No #{kbps}k data for segment #{segment_number}")

        data ->
          path = segment_path(state.live_stream_id, kbps, segment_name, state.storage)
          write_file(path, data, state.storage)
      end
    end)

    new_entry  = %{name: segment_name, duration: duration}
    new_window = (state.playlist_window ++ [new_entry]) |> Enum.take(-@playlist_window)
    all_segments = state.all_segments ++ [new_entry]

    Enum.each(@bitrates, fn kbps ->
      write_live_playlist(state.live_stream_id, kbps, new_window, segment_number, state.storage)
    end)

    segment_urls = build_segment_urls(state.live_stream_id, segment_name, state.storage)
    StreamChannel.notify_segment_ready(state.live_stream_id, segment_number, segment_urls)

    %{state |
      segment_count:      segment_number,
      playlist_window:    new_window,
      all_segments:       all_segments,
      accumulator:        %{},    # reset for next segment
      accumulated_frames: 0
    }
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
    sequence_start = max(0, media_sequence - @playlist_window)

    segments_content =
      Enum.map_join(window, "\n", fn %{name: name, duration: duration} ->
        "#EXTINF:#{duration},\n#{kbps}k/#{name}"
      end)

    content = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:#{@target_duration}
    #EXT-X-MEDIA-SEQUENCE:#{sequence_start}

    #{segments_content}
    """

    path = playlist_path(live_stream_id, kbps, storage)
    write_file(path, content, storage)
  end

  defp write_archive_playlist(live_stream_id, kbps, all_segments, storage) do
    segments_content =
      Enum.map_join(all_segments, "\n", fn %{name: name, duration: duration} ->
        "#EXTINF:#{duration},\n#{kbps}k/#{name}"
      end)

    content = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:#{@target_duration}
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

    content_type =
      if String.ends_with?(path, ".m3u8"),
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
          :local -> "/segments/#{live_stream_id}/#{kbps}k/#{segment_name}"
          :s3    -> "#{storage.base_url}/broadcasters/#{live_stream_id}/#{kbps}k/#{segment_name}"
        end

      {kbps, url}
    end)
  end

  defp storage_config do
    config = Application.get_env(:pod, :storage, adapter: :local, local_path: "priv/segments")

    %{
      adapter:    config[:adapter]    || :local,
      local_path: config[:local_path] || "priv/segments",
      bucket:     config[:bucket],
      base_url:   config[:base_url]   || ""
    }
  end
end
