defmodule Pod.BroadcasterSupervisor.Ingest.Transcoder do
  @moduledoc """
  A pooled GenServer worker that receives buffered AAC frames from a broadcaster
  and returns ADTS-framed audio to the caller.

  ## Why no per-dispatch FFmpeg re-encoding

  Previously this module re-encoded each 3-frame batch at 128k/192k/320k using
  separate FFmpeg invocations. This caused audible gaps throughout playback:
  each FFmpeg process starts with a fresh AAC encoder, which introduces priming
  delay at the start of every batch — a discontinuity every 64 ms.

  The fix: wrap frames in ADTS format directly and return the native bitrate
  for all quality variants. ADTS-framed AAC is self-describing (each frame
  carries its own sync word and length) and concatenates cleanly without gaps.

  Quality-based encoding is handled once at stream end by AudioPackagingWorker
  (FFmpeg HLS → MP3), where encoder state continuity is not an issue.

  ## Input contract

  The caller (AudioBuffer flush) passes:
    - `frames`     — list of raw AAC binaries (stripped of RTMP wrapper)
    - `aac_config` — the parsed AAC config map from the stream's sequence header:
                     `%{profile: integer, sample_rate_index: integer, channels: integer}`
    - `reply_to`   — the PID that will receive the result message

  ## Result message

  The `reply_to` process receives:

      {:transcoded, {:ok, frame_count, %{128 => binary, 192 => binary, 320 => binary}}}
      {:transcoded, {:error, reason}}

  `frame_count` is the actual number of AAC frames in this dispatch — may be
  less than 3 when Season's flush_timeout drains a partial buffer. The Segmenter
  uses this count to track accumulated frames accurately.
  """

  use GenServer
  require Logger
  import Bitwise

  alias Pod.BroadcasterSupervisor.Ingest.TranscoderPool

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
  # ADTS passthrough — no re-encoding
  # ---------------------------------------------------------------------------

  defp run_all_bitrates(frames, aac_config) do
    frame_count = length(frames)
    adts_binary = wrap_frames_in_adts(frames, aac_config)
    Logger.debug("[Transcoder] ADTS passthrough — #{byte_size(adts_binary)} bytes, #{frame_count} frames")
    # Return the same native-bitrate ADTS binary for all quality slots.
    # Quality re-encoding happens once in AudioPackagingWorker (HLS → MP3).
    {:ok, frame_count, %{128 => adts_binary, 192 => adts_binary, 320 => adts_binary}}
  end
end
