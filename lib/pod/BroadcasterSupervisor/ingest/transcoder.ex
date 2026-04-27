defmodule Pod.BroadcasterSupervisor.Ingest.Transcoder do
  @moduledoc """
  A pooled GenServer worker that receives buffered AAC frames from a broadcaster,
  re-encodes them at three bitrates (128k, 192k, 320k) using FFmpeg, and returns
  ADTS-wrapped segments to the caller.

  ## Input contract

  The caller (AudioBuffer flush) passes:
    - `frames`     — list of raw AAC binaries (stripped of RTMP wrapper)
    - `aac_config` — the parsed AAC config map from the stream's sequence header:
                     `%{profile: integer, sample_rate_index: integer, channels: integer}`
    - `reply_to`   — the PID that will receive the result message

  ## Why we wrap in ADTS before piping to FFmpeg

  FFmpeg needs a self-describing container to understand the AAC input. Raw AAC
  frames on their own have no framing — FFmpeg cannot determine sample rate,
  channel count, or profile without it. ADTS headers (7 bytes each) provide
  exactly that framing. We build them ourselves using the `aac_config` parsed
  earlier from the RTMP sequence header, reusing the same logic from AudioFrame.

  ## Why one FFmpeg process per bitrate (not one with multiple outputs)

  FFmpeg *can* output multiple bitrates in one process, but only to files or
  named pipes — not to a single stdout. Writing to temp files would require
  cleanup logic and disk I/O on every flush. Separate processes piping to
  stdout keep everything in memory and let us collect each result cleanly.
  With a pool of 100 workers, three short-lived FFmpeg processes per flush
  is acceptable — each runs for milliseconds on 2-3 frames of audio.

  ## Result message

  The `reply_to` process receives:

      {:transcoded, {:ok, %{128 => binary, 192 => binary, 320 => binary}}}
      {:transcoded, {:error, reason}}
  """

  use GenServer
  require Logger
  import Bitwise

  alias Pod.BroadcasterSupervisor.Ingest.TranscoderPool

  @bitrates [128, 192, 320]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :idle)
  end

  @doc """
  Dispatches an async transcode job to a checked-out worker.

  - `frames`     - list of raw AAC frame binaries (from AudioBuffer)
  - `aac_config` - %{profile:, sample_rate_index:, channels:} from the sequence header
  - `reply_to`   - pid that receives {:transcoded, result}
  """
  def transcode(pid, frames, aac_config, reply_to) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:transcode, frames, aac_config, reply_to})
    else
      {:error, :worker_dead}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(:idle) do
    # Register into the pool on every start/restart.
    # Uses register/1 (not checkin/1) — register inserts fresh PIDs
    # unconditionally, checkin only updates existing entries.
    TranscoderPool.register(self())
    {:ok, :idle}
  end

  @impl true
  def handle_cast({:transcode, frames, aac_config, reply_to}, :idle) do
    Logger.debug("[Transcoder #{inspect(self())}] Starting transcode — #{length(frames)} frames")

    result = run_all_bitrates(frames, aac_config)
    send(reply_to, {:transcoded, result})

    TranscoderPool.checkin(self())
    {:noreply, :idle}
  end

  # Guard: should not happen if pool logic is correct, but never crash silently.
  def handle_cast({:transcode, _frames, _config, reply_to}, state) do
    Logger.warning("[Transcoder #{inspect(self())}] Received work in state=#{state}, rejecting")
    send(reply_to, {:transcoded, {:error, :worker_busy}})
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # ADTS wrapping
  #
  # Mirrors add_adts_header/2 from AudioFrame — kept here so the Transcoder is
  # self-contained and AudioFrame does not need to be called as a dependency.
  # ---------------------------------------------------------------------------

  defp wrap_frames_in_adts(frames, aac_config) do
    frames
    |> Enum.map(&add_adts_header(&1, aac_config))
    |> IO.iodata_to_binary()
  end

  defp add_adts_header(frame, %{
         profile: profile,
         sample_rate_index: sr_index,
         channels: channels
       }) do
    # ADTS frame length = 7 bytes header + raw AAC frame
    frame_length = byte_size(frame) + 7

    # ADTS sync word (0xFFF) + ID=0 (MPEG-4) + layer=0 + no CRC protection bit (1)
    byte0 = 0xFF
    byte1 = 0xF1

    # profile (2 bits, stored as profile-1) | sample_rate_index (4 bits) | private=0 | channels[2]
    byte2 = profile <<< 6 ||| sr_index <<< 2 ||| channels >>> 2

    # channels[0:1] (2 bits) | originality/copy/home (3 bits=0) | frame_length[12:11] (2 bits)
    byte3 = (channels &&& 3) <<< 6 ||| frame_length >>> 11

    # frame_length[10:3]
    byte4 = frame_length >>> 3 &&& 0xFF

    # frame_length[2:0] (3 bits) | buffer fullness=0x7FF (5 bits of 11)
    byte5 = (frame_length &&& 7) <<< 5 ||| 0x1F

    # buffer fullness remaining 6 bits=0x3F | number_of_raw_data_blocks_in_frame=0
    byte6 = 0xFC

    <<byte0, byte1, byte2, byte3, byte4, byte5, byte6>> <> frame
  end

  # ---------------------------------------------------------------------------
  # FFmpeg orchestration
  # ---------------------------------------------------------------------------

  defp run_all_bitrates(frames, aac_config) do
    # Wrap frames once — all three FFmpeg processes receive the same binary.
    adts_binary = wrap_frames_in_adts(frames, aac_config)

    Logger.debug("[Transcoder] ADTS input size: #{byte_size(adts_binary)} bytes")

    results =
      Enum.map(@bitrates, fn kbps ->
        case run_ffmpeg(adts_binary, kbps) do
          {:ok, segment} ->
            Logger.debug("[Transcoder] #{kbps}k → #{byte_size(segment)} bytes output")
            {:ok, {kbps, segment}}

          {:error, reason} ->
            Logger.error("[Transcoder] #{kbps}k failed: #{inspect(reason)}")
            {:error, {kbps, reason}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      segments =
        results
        |> Enum.map(fn {:ok, {kbps, segment}} -> {kbps, segment} end)
        |> Map.new()

      # %{128 => <<...>>, 192 => <<...>>, 320 => <<...>>}
      {:ok, segments}
    else
      {:error, {:ffmpeg_partial_failure, errors}}
    end
  end

  defp run_ffmpeg(adts_binary, kbps) do
    tmp_path =
      System.tmp_dir!()
      |> Path.join("pod_#{kbps}_#{:erlang.unique_integer([:positive])}.aac")

    out_path =
      System.tmp_dir!()
      |> Path.join("pod_#{kbps}_#{:erlang.unique_integer([:positive])}_out.aac")

    try do
      File.write!(tmp_path, adts_binary)

      # Write to an output file instead of pipe:1 — avoids System.cmd stdout
      # mixing with stderr when stderr_to_stdout: true is needed to prevent
      # the stderr pipe buffer from filling and blocking FFmpeg.
      args = ffmpeg_args(kbps, tmp_path, out_path)

      case System.cmd(ffmpeg_bin(), args, stderr_to_stdout: true) do
        {_stderr, 0} ->
          case File.read(out_path) do
            {:ok, data} -> {:ok, data}
            {:error, reason} -> {:error, {:output_read_failed, reason}}
          end

        {stderr_output, status} ->
          Logger.error("[Transcoder] FFmpeg #{kbps}k failed (#{status}): #{stderr_output}")
          {:error, {:ffmpeg_exit, status}}
      end
    after
      File.rm(tmp_path)
      File.rm(out_path)
    end
  end

  defp ffmpeg_args(kbps, input_path, output_path) do
    [
      "-hide_banner",
      "-loglevel", "error",
      "-f", "aac",
      "-i", input_path,
      "-c:a", "aac",
      "-b:a", "#{kbps}k",
      "-f", "adts",
      output_path    # write to file, not pipe:1
    ]
  end

  defp ffmpeg_bin do
    System.find_executable("ffmpeg") ||
      raise "[Transcoder] ffmpeg not found in PATH — ensure it is installed on this node"
  end
end
