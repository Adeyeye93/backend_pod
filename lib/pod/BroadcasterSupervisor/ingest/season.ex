defmodule Pod.BroadcasterSupervisor.Ingest.Season do
  use GenServer
  require Logger
  alias Pod.BroadcasterSupervisor.Ingest
  alias Pod.BroadcasterSupervisor.RTMP

  defstruct [
    :id,
    :socket,
    :audio_buffer,
    :transcoder,
    :circuit,
    chunk_size: 128,
    bitrate: nil,
    buffer: <<>>,
    hs: :c0,              # ✓ ADDED
    frames_in: 0,
    last_audio_at: nil,
    state: :handshaking
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {:ok, audio_buffer} = Ingest.AudioBuffer.start_link(max_frames: 3)
    {:ok, transcoder} = Ingest.Transcoder.start_link()
    circuit = Ingest.CircuitBreaker.new()

    state = %__MODULE__{
      id: opts[:id],
      socket: opts[:socket],
      audio_buffer: audio_buffer,
      transcoder: transcoder,
      circuit: circuit
    }

    if state.circuit.state == :open do
      Logger.error("Circuit open dropping stream")
      {:stop, :circuit_open, state}
    end

    # ✓ START READING FROM SOCKET
    send(self(), :start_reading)
    {:ok, state}
  end

  # ✓ HANDLE INCOMING DATA
  @impl true
  def handle_info(:start_reading, state) do
    case :gen_tcp.recv(state.socket, 0) do
      {:ok, data} ->
        new_buffer = state.buffer <> data

        # Check if we're still handshaking
        case state.state do
          :handshaking ->
            new_state = handle_handshake(new_buffer, state)
            send(self(), :start_reading)
            {:noreply, new_state}

          :streaming ->
            # Process audio frame
            new_state = handle_audio_frame(new_buffer, state)
            send(self(), :start_reading)
            {:noreply, new_state}
        end

      {:error, :closed} ->
        Logger.info("Broadcaster #{state.id} disconnected")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.error("Socket error: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  defp handle_handshake(buffer, state) do
    case RTMP.HandsakeProtocol.handle(%{state | buffer: buffer}) do
      {:ok, new_state, actions} ->
        Enum.each(actions, &execute_action(new_state.socket, &1))
        new_state

      {:done, new_state} ->
        Logger.info("Handshake complete for #{state.id}")
        %{new_state | state: :streaming}

      {:more, new_state} ->
        new_state
    end
  end

  defp handle_audio_frame(buffer, state) do
    # TODO: Parse RTMP audio frame from buffer
    %{state | buffer: buffer}
  end

  defp execute_action(socket, {:send, bin}) do
    :gen_tcp.send(socket, bin)
  end
end
