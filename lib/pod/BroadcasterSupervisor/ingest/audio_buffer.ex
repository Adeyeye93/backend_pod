defmodule Pod.BroadcasterSupervisor.Ingest.AudioBuffer do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    max_frames = Keyword.get(opts, :max_frames, 3)
    {:ok, %{frames: [], max_frames: max_frames}}
  end

  def push(pid, frame) when is_binary(frame) and byte_size(frame) > 0 do
    GenServer.cast(pid, {:push, frame})
  end

  def push(_pid, _frame) do
    # Ignore empty frames (config frames, etc)
    Logger.debug("Ignoring empty audio frame")
    :ok
  end

  def status(pid) do
    GenServer.call(pid, :status)
  end

  def clear(pid) do
    GenServer.cast(pid, :clear)
  end

  @impl true
  def handle_cast({:push, frame}, state) do
    new_frames = state.frames ++ [frame]
    Logger.debug("Audio frame added, buffer: #{length(new_frames)}/#{state.max_frames}")

    {:noreply, %{state | frames: new_frames}}
  end

  def handle_cast(:clear, state) do
    Logger.debug("Audio buffer cleared")
    {:noreply, %{state | frames: []}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = if length(state.frames) >= state.max_frames do
      {:full, state.frames}
    else
      {:not_full, length(state.frames)}
    end

    {:reply, status, state}
  end
end
