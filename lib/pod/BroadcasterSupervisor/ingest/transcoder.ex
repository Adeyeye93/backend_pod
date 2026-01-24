defmodule Pod.BroadcasterSupervisor.Ingest.Transcoder do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil)
  end

  @impl true
  def init(_) do
    port =
      Port.open(
        {:spawn_executable, ffmpeg_path()},
        [:binary, :exit_status]
      )

    {:ok, port}
  end

  def push(pid, frames) do
    GenServer.cast(pid, {:transcode, frames})
  end

  @impl true
  def handle_cast({:transcode, frames}, port) do
    binary = IO.iodata_to_binary(frames)
    Port.command(port, binary)
    {:noreply, port}
  end

  defp ffmpeg_path do
    System.find_executable("ffmpeg") || "/usr/bin/ffmpeg"
  end
end
