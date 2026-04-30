defmodule PodWeb.ChannelSocket do
  use Phoenix.Socket
  require Logger

  alias Pod.Accounts.Guardian

  ## Channels
  channel "stream:*", PodWeb.StreamChannel
  channel "scheduled_stream:*", PodWeb.ScheduledStreamChannel
  channel "feed:*", PodWeb.FeedChannel


  # ---------------------------------------------------------------------------
  # Connection — verify JWT before allowing any WebSocket connection
  #
  # The client must pass a valid JWT as a param when connecting:
  #   let socket = new Socket("/socket", {params: {token: userToken}})
  #
  # We verify it here once — if valid, we store the user_id on the socket
  # so every channel joined on this socket has access to it via socket.assigns.
  # ---------------------------------------------------------------------------

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Guardian.decode_and_verify(token) do
      {:ok, claims} ->
        user_id = claims["sub"]
        Logger.debug("[ChannelSocket] Authenticated connection for user: #{user_id}")
        {:ok, assign(socket, :user_id, user_id)}

      {:error, reason} ->
        Logger.warning("[ChannelSocket] Rejected connection — invalid token: #{inspect(reason)}")
        :error
    end
  end

  # Reject connections that don't provide a token at all
  def connect(_params, _socket, _connect_info) do
    Logger.warning("[ChannelSocket] Rejected connection — no token provided")
    :error
  end

  # Socket ID allows broadcasting a disconnect to all of a user's connections.
  # e.g. PodWeb.Endpoint.broadcast("user_socket:#{user_id}", "disconnect", %{})
  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
