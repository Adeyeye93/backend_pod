defmodule PodWeb.ListeningChannel do
  use Phoenix.Channel

  alias Pod.ListeningPresence
  require Logger

  # Intercept presence_diff so we can also push listener_count
  # alongside the standard Presence event on every join/leave.
  intercept ["presence_diff"]

  # ---------------------------------------------------------------------------
  # Join — topic: "listening:{recording_id}"
  #
  # Auth is already verified at socket connect time (JWT → user_id in assigns).
  # We only need to confirm the assign is present; if somehow it isn't we reject.
  # ---------------------------------------------------------------------------

  @impl true
  def join("listening:" <> recording_id, _params, socket) do
    case socket.assigns[:user_id] do
      nil ->
        {:error, %{reason: "unauthorized"}}

      _user_id ->
        socket = assign(socket, :recording_id, recording_id)
        send(self(), :after_join)
        {:ok, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # After join — track in Presence, push initial state to the joiner
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id

    {:ok, _} = ListeningPresence.track(socket, user_id, %{
      user_id:   user_id,
      joined_at: System.system_time(:second)
    })

    presences = ListeningPresence.list(socket.topic)

    # Send current full presence map to the joiner only
    push(socket, "presence_state", presences)

    # Send the simple count as well (for clients that skip Presence parsing)
    push(socket, "listener_count", %{count: map_size(presences)})

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Intercept presence_diff
  #
  # Presence broadcasts presence_diff automatically to all subscribers.
  # We intercept it to:
  #   1. Forward the diff to the client unchanged
  #   2. Piggyback a listener_count event so simple clients get the total
  # ---------------------------------------------------------------------------

  @impl true
  def handle_out("presence_diff", diff, socket) do
    push(socket, "presence_diff", diff)

    presences = ListeningPresence.list(socket.topic)
    push(socket, "listener_count", %{count: map_size(presences)})

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Terminate — Presence automatically unregisters the user on disconnect
  # ---------------------------------------------------------------------------

  @impl true
  def terminate(reason, socket) do
    Logger.debug(
      "[ListeningChannel] #{socket.assigns[:user_id]} left #{socket.topic} (#{inspect(reason)})"
    )
    :ok
  end
end
