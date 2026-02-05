defmodule Pod.RTMPServer do
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
        Logger.info("RTMP Server listening on port #{port}")
        send(self(), :accept)
        {:ok, listen_socket}

      {:error, reason} ->
        Logger.error("Failed to start RTMP server: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        Logger.info("New RTMP connection accepted")

        # Generate unique ID for this broadcaster
        broadcaster_id = UUID.uuid4()

        # Start a Season GenServer for this broadcaster
        {:ok, _pid} = Pod.BroadcasterSupervisor.Ingest.Season.start_link(%{
          id: broadcaster_id,
          socket: socket
        })


        Logger.info("Started Season for broadcaster: #{broadcaster_id}")

        # Continue accepting more connections
        send(self(), :accept)
        {:noreply, listen_socket}

      {:error, reason} ->
        Logger.error("Accept error: #{inspect(reason)}")
        send(self(), :accept)
        {:noreply, listen_socket}
    end
  end
end
