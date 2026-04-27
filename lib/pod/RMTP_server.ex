defmodule Pod.RTMPServer do
  @moduledoc """
  Listens on port 1935 for incoming RTMP broadcaster connections.

  This module's only responsibility is accepting TCP connections and handing
  them off to a Season process. It does NOT authenticate here — authentication
  happens inside Season when the RTMP "publish" AMF command arrives, because
  the stream key is not available until that point in the RTMP protocol.

  ## Connection lifecycle

    1. Broadcaster opens a TCP connection to port 1935
    2. RTMPServer accepts and starts a Season in :pending state
    3. Season handles the RTMP handshake
    4. Season receives the "publish" AMF command containing the stream key
    5. Season authenticates the stream key against the database
    6. If valid → Season transitions to :streaming, audio begins flowing
    7. If invalid → Season sends an AMF error response and closes the socket
  """

  use GenServer
  require Logger

  def start_link(opts) do
    port = Keyword.get(opts, :port, 1935)
    GenServer.start_link(__MODULE__, port, name: __MODULE__)
  end
  
  @impl true
  def init(port) do
    opts = [:binary, active: false, reuseaddr: true]

    case :gen_tcp.listen(port, opts) do
      {:ok, listen_socket} ->
        Logger.info("[RTMPServer] Listening on port #{port}")
        send(self(), :accept)
        {:ok, listen_socket}

      {:error, :eaddrinuse} ->
        Logger.error("[RTMPServer] Port #{port} is already in use")
        {:stop, :eaddrinuse}

      {:error, reason} ->
        Logger.error("[RTMPServer] Failed to start: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        Logger.info("[RTMPServer] New TCP connection accepted")

        # Start Season in a pending state — no ID yet.
        # The real live_stream_id will be set by Season after the
        # "publish" AMF command arrives and authenticates successfully.
        case Pod.BroadcasterSupervisor.start_broadcaster(socket) do
          {:ok, pid} ->
            Logger.info("[RTMPServer] Season started — pid: #{inspect(pid)}, awaiting stream key")

          {:error, reason} ->
            Logger.error("[RTMPServer] Failed to start Season: #{inspect(reason)}")
            :gen_tcp.close(socket)
        end

        # Always loop back — RTMPServer must keep accepting new connections
        # regardless of whether the last Season started successfully
        send(self(), :accept)
        {:noreply, listen_socket}

      {:error, :closed} ->
        # Listen socket was closed — server is shutting down
        Logger.info("[RTMPServer] Listen socket closed, shutting down")
        {:stop, :normal, listen_socket}

      {:error, reason} ->
        Logger.error("[RTMPServer] Accept error: #{inspect(reason)}")
        send(self(), :accept)
        {:noreply, listen_socket}
    end
  end
end
