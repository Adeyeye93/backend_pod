defmodule Pod.BroadcasterSupervisor.Ingest.AudioBuffer do
  use GenServer

  defstruct frames: :queue.new(),
            max_frames: 3

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{max_frames: opts[:max_frames]}}
  end

  @impl true
  def handle_cast({:audio_frame, frame}, state) do
    frames =
      state.frames
      |> :queue.in(frame)
      |> trim(state.max_frames)

    {:noreply, %{state | frames: frames}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :queue.to_list(state.frames), %{state | frames: :queue.new()}}
  end

  defp trim(queue, max) do
    if :queue.len(queue) > max do
      {_dropped, q} = :queue.out(queue)
      q
    else
      queue
    end
  end
end
