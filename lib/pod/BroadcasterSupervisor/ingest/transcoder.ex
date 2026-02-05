defmodule Pod.BroadcasterSupervisor.Ingest.Transcoder do
  use GenServer
  require Logger
  alias Pod.BroadcasterSupervisor.Ingest.TranscoderPool

  def start_link() do
    GenServer.start_link(__MODULE__, :idle)
  end

  @impl true
  def init(_) do
    TranscoderPool.checkin(self())
    {:ok, :idle}
  end

  def transcode(pid, audio, reply_to) do
    # Check if process is alive before sending
    if Process.alive?(pid) do
      GenServer.cast(pid, {:transcode, audio, reply_to})
    else
      {:error, :worker_dead}
    end
  end

  @impl true
  def handle_cast({:transcode, audio, reply_to}, :idle) do
    result = run_ffmpeg(audio)
    send(reply_to, {:transcoded, result})

    TranscoderPool.checkin(self())
    {:noreply, :idle}
  end

  def run_ffmpeg(audio) do
    port =
      Port.open(
        {:spawn_executable, ffmpeg()},
        [
          :binary,
          :exit_status,
          args: ffmpeg_args()
        ]
      )

    Port.command(port, audio)
    collect_output(port, <<>>)
  end

  defp ffmpeg_args do
    [
      "-f",
      "s16le",
      "-ar",
      "48000",
      "-ac",
      "1",
      "-i",
      "pipe:0",

      # multi-bitrate outputs
      "-map",
      "0:a",
      "-b:a:0",
      "128k",
      "-map",
      "0:a",
      "-b:a:1",
      "192k",
      "-map",
      "0:a",
      "-b:a:2",
      "320k",
      "-f",
      "adts",
      "pipe:1"
    ]
  end

  defp collect_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, status}} ->
        {:error, {:ffmpeg_failed, status}}
    after
      5_000 ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp ffmpeg do
    "ffmpeg"
  end
end
