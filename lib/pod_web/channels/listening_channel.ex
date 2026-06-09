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
  # Optional join param: current_position_seconds (integer, default 0)
  # ---------------------------------------------------------------------------

  @impl true
  def join("listening:" <> recording_id, params, socket) do
    case socket.assigns[:user_id] do
      nil ->
        {:error, %{reason: "unauthorized"}}

      _user_id ->
        position = case Map.get(params, "current_position_seconds") do
          p when is_integer(p) and p >= 0 -> p
          _ -> 0
        end

        socket =
          socket
          |> assign(:recording_id, recording_id)
          |> assign(:initial_position, position)

        send(self(), :after_join)
        {:ok, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # After join — track in Presence, push initial state to the joiner
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:after_join, socket) do
    user_id      = socket.assigns.user_id
    recording_id = socket.assigns.recording_id

    Pod.ListeningRegistry.touch(recording_id)

    {:ok, _} = ListeningPresence.track(socket, user_id, %{
      user_id:                  user_id,
      joined_at:                System.system_time(:second),
      current_position_seconds: socket.assigns[:initial_position] || 0
    })

    presences = ListeningPresence.list(socket.topic)
    push(socket, "presence_state", presences)
    push(socket, "listener_count", %{count: map_size(presences)})

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Client → server: periodic position sync
  # Mobile sends: { "position": 2540 }
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("sync_position", %{"position" => position}, socket)
      when is_integer(position) and position >= 0 do
    ListeningPresence.update(socket, socket.assigns.user_id, fn meta ->
      Map.put(meta, :current_position_seconds, position)
    end)

    {:noreply, socket}
  end

  def handle_in("sync_position", _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Intercept presence_diff — forward diff + push updated listener_count
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
