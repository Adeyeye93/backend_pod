defmodule Pod.BroadcasterSupervisor.Ingest.Season do
  @moduledoc """
  One GenServer per active broadcaster connection.

  ## State machine

    :handshaking → :pending → :streaming

  - :handshaking  TCP connected, RTMP handshake in progress
  - :pending      Handshake done, waiting for stream key authentication
  - :streaming    Authenticated, audio is flowing, transcoder pool active

  ## Authentication flow (no deadlock)

  When the "publish" AMF command arrives, AudioFrame extracts the stream key
  and returns it as `state.pending_auth`. Season detects this field after
  handle_audio_frame returns and calls Stream.authenticate_stream/1 itself.
  This avoids the deadlock that would occur if AudioFrame called
  Season.authenticate/2 (a GenServer.call) from inside a Season callback.

  ## Transcoding flow

    Buffer fills (3 frames) or flush timer fires
      → AudioFrame.flush_and_transcode/2
        → TranscoderPool.checkout/0
          → Transcoder.transcode/4 (async cast)
            → {:transcoded, result} arrives in handle_info
              → Segmenter.write_segment/2
  """

  use GenServer
  require Logger

  alias Pod.BroadcasterSupervisor.Ingest
  alias Pod.BroadcasterSupervisor.RTMP
  alias Pod.BroadcasterSupervisor.Handler.AudioFrame
  alias Pod.Stream

  defstruct [
    :live_stream_id,
    :socket,
    :audio_buffer,
    :circuit,
    :flush_timer,
    :session_id,
    :segmenter_pid,
    # Set by AudioFrame when "publish" arrives — Season handles auth after
    pending_auth: nil,
    chunk_size: 128,
    bitrate: nil,
    buffer: <<>>,
    hs: :c0,
    s0: nil,
    s1: nil,
    s2: nil,
    frames_in: 0,
    last_audio_at: nil,
    # :handshaking | :pending | :streaming
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

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # ---------------------------------------------------------------------------
  # Init
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, audio_buffer} = Ingest.AudioBuffer.start_link(max_frames: 3)
    circuit = Ingest.CircuitBreaker.new()

    state = %__MODULE__{
      live_stream_id: nil,
      socket: opts[:socket],
      session_id: opts[:session_id],
      audio_buffer: audio_buffer,
      circuit: circuit
    }

    if circuit.state == :open do
      Logger.error("[Season] Circuit breaker open — rejecting connection")
      {:stop, :circuit_open, state}
    else
      send(self(), :start_reading)
      {:ok, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Main read loop
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:start_reading, state) do
    case :gen_tcp.recv(state.socket, 0) do
      {:ok, data} ->
        new_buffer = state.buffer <> data

        new_state =
          case state.state do
            :handshaking ->
              handle_handshake(new_buffer, state)

            :pending ->
              # Still in pending — process AMF commands via AudioFrame.
              # AudioFrame may set pending_auth on the returned state
              # if it extracts a stream key from "publish".
              state_after_frame = AudioFrame.handle_audio_frame(new_buffer, state)
              maybe_authenticate(state_after_frame)

            :streaming ->
              AudioFrame.handle_audio_frame(new_buffer, state)
          end

        send(self(), :start_reading)
        {:noreply, new_state}

      {:error, :closed} ->
        Logger.info("[Season] Broadcaster disconnected — stream: #{state.live_stream_id || "unauthenticated"}")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.error("[Season] Socket error: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Flush timer
  # Fires every 3 seconds — flushes partial buffers for irregular senders
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:flush_timeout, state) do
    frames = Ingest.AudioBuffer.drain(state.audio_buffer)

    if frames != [] do
      AudioFrame.flush_and_transcode(frames, state)
    end

    timer = Process.send_after(self(), :flush_timeout, 3_000)
    {:noreply, %{state | flush_timer: timer}}
  end

  # ---------------------------------------------------------------------------
  # Transcoder results
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:transcoded, {:ok, segments}}, state) do
    # segments = %{128 => <<binary>>, 192 => <<binary>>, 320 => <<binary>>}
    if state.live_stream_id do
      case lookup_segmenter(state.session_id) do
        {:ok, segmenter_pid} ->
          Ingest.Segmenter.write_segment(segmenter_pid, state.live_stream_id, segments)
        {:error, :not_found} ->
          Logger.warning("[Season] Segmenter not found for session #{state.session_id} — dropping segments")
      end
    else
      Logger.warning("[Season] Received transcoded result but no live_stream_id — dropping")
    end

    {:noreply, state}
  end

  def handle_info({:transcoded, {:error, reason}}, state) do
    Logger.error("[Season] Transcoding failed: #{inspect(reason)}")
    new_circuit = Ingest.CircuitBreaker.record_failure(state.circuit)

    if Ingest.CircuitBreaker.open?(new_circuit) do
      Logger.error("[Season] Circuit breaker opened — too many transcoding failures, terminating")
      {:stop, :circuit_open, %{state | circuit: new_circuit}}
    else
      {:noreply, %{state | circuit: new_circuit}}
    end
  end

  # ---------------------------------------------------------------------------
  # Terminate
  # ---------------------------------------------------------------------------

  @impl true
  def terminate(reason, state) do
    Logger.info("[Season] Terminating — #{inspect(reason)}")

    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)

    # Tell Segmenter to finalise the archive — writes #EXT-X-ENDLIST
    # and updates the LiveStream DB record with final stats.
    # Segmenter handles the DB end_stream call so we don't do it here.
    if state.live_stream_id do
      case lookup_segmenter(state.session_id) do
        {:ok, segmenter_pid} ->
          Ingest.Segmenter.finalise(segmenter_pid)
        {:error, :not_found} ->
          Logger.warning("[Season] Segmenter not found during terminate — archive may be incomplete")
          # Fall back to direct DB update if Segmenter is gone
          case Stream.get_stream(state.live_stream_id) do
            nil -> :ok
            live_stream -> Stream.end_stream(live_stream, %{})
          end
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private — segmenter lookup via Registry
  # ---------------------------------------------------------------------------

  defp lookup_segmenter(nil), do: {:error, :not_found}

  defp lookup_segmenter(session_id) do
    case Registry.lookup(Pod.SessionRegistry, {session_id, :segmenter}) do
      [{pid, _}] -> {:ok, pid}
      []         -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — authentication
  #
  # Called after handle_audio_frame returns whenever state.pending_auth is set.
  # This is how we avoid the GenServer.call deadlock — AudioFrame sets
  # pending_auth and returns, then Season handles the auth here outside
  # of any nested call.
  # ---------------------------------------------------------------------------

  defp maybe_authenticate(%{pending_auth: nil} = state), do: state

  defp maybe_authenticate(%{pending_auth: stream_key} = state) do
    Logger.info("[Season] Authenticating stream key")

    case Stream.authenticate_stream(stream_key) do
      {:ok, live_stream} ->
        Logger.info("[Season] ✓ Authenticated — live_stream_id: #{live_stream.id}")

        # Mark stream as live in the database
        Stream.start_stream(live_stream)

        # Send AMF publish success response to the broadcaster's client
        AudioFrame.send_amf_publish_response(state.socket)

        # Start the flush timer now that audio is expected
        timer = Process.send_after(self(), :flush_timeout, 3_000)

        %{state |
          live_stream_id: live_stream.id,
          state: :streaming,
          pending_auth: nil,
          flush_timer: timer
        }

      {:error, :not_found} ->
        Logger.warning("[Season] ✗ Stream key not found — closing connection")
        AudioFrame.send_amf_publish_error(state.socket, "Stream key not found. Check your streaming settings.")
        :gen_tcp.close(state.socket)
        %{state | pending_auth: nil}

      {:error, {:not_scheduled, status}} ->
        Logger.warning("[Season] ✗ Stream is #{status} — closing connection")
        AudioFrame.send_amf_publish_error(state.socket, "Stream is #{status}. Only scheduled streams can go live.")
        :gen_tcp.close(state.socket)
        %{state | pending_auth: nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — handshake
  # ---------------------------------------------------------------------------

  defp handle_handshake(buffer, state) do
    case RTMP.HandsakeProtocol.handle(%{state | buffer: buffer}) do
      {:ok, new_state, actions} ->
        Enum.each(actions, &execute_action(new_state.socket, &1))
        new_state

      {:done, new_state} ->
        Logger.info("[Season] ✓ Handshake complete — waiting for stream key")
        %{new_state | state: :pending}

      {:more, new_state} ->
        new_state
    end
  end

  defp execute_action(socket, {:send, bin}), do: :gen_tcp.send(socket, bin)
end
