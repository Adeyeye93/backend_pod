defmodule Pod.BroadcasterSupervisor.Ingest.AudioBuffer do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def push(pid, frame) when is_binary(frame) and byte_size(frame) > 0 do
    GenServer.cast(pid, {:push, frame})
  end

  def push(_pid, _frame) do
    Logger.debug("Ignoring empty or non-binary audio frame")
    :ok
  end

  def status(pid) do
    GenServer.call(pid, :status)
  end

  def clear(pid) do
    GenServer.cast(pid, :clear)
  end

  @doc """
  Atomically returns all current frames and clears the buffer in one operation.

  This is the safe alternative to calling status/1 then clear/1 separately.
  The problem with doing them separately is that a push/1 can arrive between
  the two calls — that frame would then be wiped by the clear, losing audio
  silently. drain/1 handles both inside a single GenServer call so nothing
  can interrupt it.

  Returns [] if the buffer is empty.
  """
  def drain(pid) do
    GenServer.call(pid, :drain)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    max_frames = Keyword.get(opts, :max_frames, 3)
    {:ok, %{frames: [], max_frames: max_frames}}
  end

  @impl true
  def handle_cast({:push, frame}, state) do
    # Prepend then reverse only when needed — more efficient than ++ for growing lists.
    # At 3 frames this doesn't matter much, but it's the correct Elixir pattern.
    new_frames = [frame | state.frames] |> Enum.reverse()
    Logger.debug("Audio frame added, buffer: #{length(new_frames)}/#{state.max_frames}")
    {:noreply, %{state | frames: new_frames}}
  end

  def handle_cast(:clear, state) do
    Logger.debug("Audio buffer cleared")
    {:noreply, %{state | frames: []}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status =
      if length(state.frames) >= state.max_frames do
        {:full, state.frames}
      else
        {:not_full, length(state.frames)}
      end

    {:reply, status, state}
  end

  def handle_call(:drain, _from, state) do
    # Return whatever frames exist and clear in one atomic step.
    # Caller gets [] if buffer was empty — they should check before dispatching.
    frames = Enum.reverse(state.frames)
    {:reply, frames, %{state | frames: []}}
  end
end
