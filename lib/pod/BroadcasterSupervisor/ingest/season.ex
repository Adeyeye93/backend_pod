defmodule Pod.BroadcasterSupervisor.Ingest.Season do
  use GenServer
  require Logger
  alias Pod.BroadcasterSupervisor.Ingest
  alias Pod.BroadcasterSupervisor.RTMP
  alias Pod.BroadcasterSupervisor.Handler.AudioFrame

  defstruct [
    :id,
    :socket,
    :audio_buffer,
    :transcoder,
    :circuit,
    chunk_size: 128,
    bitrate: nil,
    buffer: <<>>,
    hs: :c0,
    s0: nil,
    s1: nil,
    s2: nil,
    frames_in: 0,
    last_audio_at: nil,
    state: :handshaking,
    csid: nil,
    timestamp: nil,
    msg_len: 0,
    msg_type: nil,
    stream_id: nil,
    received: 0,
    payload: <<>>,
    aac_config: nil
  ]

  def start_link(opts) do
    Logger.info("Season called...")
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Logger.info("Season.init called with opts: #{inspect(opts)}")

    {:ok, audio_buffer} = Ingest.AudioBuffer.start_link(max_frames: 3)
    Logger.info("✓ AudioBuffer started")

    # {:ok, transcoder} = Ingest.Transcoder.start_link()
    # Logger.info("✓ Transcoder started")

    circuit = Ingest.CircuitBreaker.new()
    Logger.info("✓ Circuit breaker created")

    state = %__MODULE__{
      id: opts[:id],
      socket: opts[:socket],
      audio_buffer: audio_buffer,
      transcoder: nil,
      circuit: circuit,
      csid: nil,
      timestamp: nil,
      msg_len: 0,
      msg_type: nil,
      stream_id: nil,
      received: 0,
      payload: <<>>,
      aac_config: nil
    }

    Logger.info("✓ State initialized for broadcaster: #{state.id}")

    if state.circuit.state == :open do
      Logger.error("Circuit open dropping stream")
      {:stop, :circuit_open, state}
    end

    Logger.info("✓ About to send :start_reading message")
    send(self(), :start_reading)
    Logger.info("✓ :start_reading message sent")

    {:ok, state}
  end

  # ✓ HANDLE INCOMING DATA
  @impl true
  def handle_info(:start_reading, state) do
    Logger.debug("handle_info(:start_reading) called, socket: #{inspect(state.socket)}")

    case :gen_tcp.recv(state.socket, 0) do
      {:ok, data} ->
        Logger.info("✓ Received #{byte_size(data)} bytes from socket")
        new_buffer = state.buffer <> data

        case state.state do
          :handshaking ->
            Logger.info("Processing as handshake")
            new_state = handle_handshake(new_buffer, state)
            send(self(), :start_reading)
            {:noreply, new_state}

          :streaming ->
            Logger.info("Processing as audio frame")
            new_state = AudioFrame.handle_audio_frame(new_buffer, state)
            send(self(), :start_reading)
            {:noreply, new_state}
        end

      {:error, :closed} ->
        Logger.info("✗ Socket closed by broadcaster #{state.id}")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.error("✗ Socket error: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  defp handle_handshake(buffer, state) do
    Logger.debug("Handshake step: #{state.hs}, buffer size: #{byte_size(buffer)}")

    case RTMP.HandsakeProtocol.handle(%{state | buffer: buffer}) do
      {:ok, new_state, actions} ->
        Logger.info("Handshake progress: #{state.hs} → #{new_state.hs}")
        Logger.debug("Sending #{length(actions)} actions")

        Enum.each(actions, fn action ->
          Logger.debug("Execute action: #{inspect(action)}")
          execute_action(new_state.socket, action)
        end)

        new_state

      {:done, new_state} ->
        Logger.info("Handshake COMPLETE for #{state.id}")
        %{new_state | state: :streaming}

      {:more, new_state} ->
        Logger.debug("Handshake needs more data")
        new_state
    end
  end

  @impl true
  def handle_info({:transcoded, {:ok, aac}}, state) do
    # Write to disk, segment, or forward
    Ingest.Segmenter.write_segment(state.id, aac)
    {:noreply, state}
  end

  def handle_info({:transcoded, {:error, reason}}, state) do
    Logger.error("Transcoding failed: #{inspect(reason)}")
    Ingest.CircuitBreaker.trip(state.circuit)
    {:noreply, state}
  end

  defp execute_action(socket, {:send, bin}) do
    :gen_tcp.send(socket, bin)
  end

end
