defmodule PodWeb.ScheduledStreamChannel do
  use Phoenix.Channel
  require Logger

  alias Pod.GuestInvites          # ✅ correct context from controller
  alias Pod.Stream, as: StreamContext
  alias Pod.Creators
  alias Pod.Stream.CreatorSerializer  # ✅ same serializer controller uses

  # ---------------------------------------------------------------------------
  # Join — only the stream host can join this channel
  # ---------------------------------------------------------------------------

  @impl true
  def join("scheduled_stream:" <> stream_id, _params, socket) do
    user_id = socket.assigns.user_id

    with %{} = creator <- Creators.get_creator_by_user(user_id),
         %{} = stream  <- StreamContext.get_stream(stream_id),
         :ok           <- check_host(stream, creator.id) do
      socket = assign(socket, :stream_id, stream_id)
      send(self(), :after_join)
      {:ok, %{stream_id: stream_id}, socket}
    else
      nil               -> {:error, %{reason: "not_found"}}
      {:error, :forbidden} -> {:error, %{reason: "unauthorized"}}
    end
  end

  # ---------------------------------------------------------------------------
  # After join — push current participants to the host immediately
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:after_join, socket) do
    stream_id = socket.assigns.stream_id
    push(socket, "participants_updated", build_participants(stream_id))
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # send_invite — host sends invite using guest's invite_key
  # Mirrors: POST /api/streams/:id/invites
  #
  # Expected payload: %{"invite_key" => "abc123..."}
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("send_invite", %{"invite_key" => invite_key}, socket) do
    stream_id = socket.assigns.stream_id
    user_id   = socket.assigns.user_id

    with %{} = creator <- Creators.get_creator_by_user(user_id),
         %{} = stream  <- StreamContext.get_stream(stream_id),
         :ok           <- check_host(stream, creator.id),
         {:ok, _invite} <- GuestInvites.invite(stream, creator.id, invite_key) do
      push(socket, "participants_updated", build_participants(stream_id))
      {:reply, :ok, socket}
    else
      nil ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}

      # Soft business rule errors — same atoms as controller
      {:error, :invite_deadline_passed} ->
        {:reply, {:error, %{reason: "invite_deadline_passed"}}, socket}

      {:error, :guest_cap_reached} ->
        {:reply, {:error, %{reason: "guest_cap_reached"}}, socket}

      {:error, :invalid_invite_key} ->
        {:reply, {:error, %{reason: "invalid_invite_key"}}, socket}

      {:error, :cannot_invite_yourself} ->
        {:reply, {:error, %{reason: "cannot_invite_yourself"}}, socket}

      {:error, :already_invited} ->
        {:reply, {:error, %{reason: "already_invited"}}, socket}

      {:error, :invites_not_available} ->
        {:reply, {:error, %{reason: "invites_not_available"}}, socket}

      {:error, changeset} ->
        {:reply, {:error, %{errors: format_errors(changeset)}}, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # cancel_invite — host cancels a sent invite
  # Mirrors: DELETE /api/streams/:id/invites/:invite_id
  #
  # Expected payload: %{"invite_id" => "..."}
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("cancel_invite", %{"invite_id" => invite_id}, socket) do
    user_id = socket.assigns.user_id

    with %{} = creator <- Creators.get_creator_by_user(user_id),
         %{} = invite  <- GuestInvites.get_invite(invite_id),
         :ok           <- check_host_owns_invite(invite, creator.id),
         {:ok, _}      <- GuestInvites.cancel(invite) do
      push(socket, "participants_updated", build_participants(socket.assigns.stream_id))
      {:reply, :ok, socket}
    else
      nil ->
        {:reply, {:error, %{reason: "invite_not_found"}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}

      {:error, :cannot_cancel} ->
        {:reply, {:error, %{reason: "only_pending_invites_can_be_cancelled"}}, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Server-side broadcast
  # Call this from guest_invite_controller after accept/decline
  # so the host's channel gets updated in real time
  # ---------------------------------------------------------------------------

  def notify_participants_updated(stream_id) do
    PodWeb.Endpoint.broadcast(
      "scheduled_stream:#{stream_id}",
      "participants_updated",
      build_participants(stream_id)
    )
  end

  # ---------------------------------------------------------------------------
  # Terminate
  # ---------------------------------------------------------------------------

  @impl true
  def terminate(reason, socket) do
    Logger.debug(
      "[ScheduledStreamChannel] left scheduled_stream:#{socket.assigns[:stream_id]} — #{inspect(reason)}"
    )
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_participants(stream_id) do
    stream = StreamContext.get_stream(stream_id)
    host   = Creators.get_creator(stream.creator_id)

    guests =
      stream_id
      |> GuestInvites.get_accepted_invites()       # ✅ same fn as controller
      |> Enum.map(fn invite ->
           Creators.get_creator(invite.guest_creator_id)
         end)
      |> Enum.map(&CreatorSerializer.serialize/1)  # ✅ same serializer as controller

    %{
      host:   CreatorSerializer.serialize(host),
      guests: guests
    }
  end

  defp check_host(%{creator_id: creator_id}, creator_id), do: :ok
  defp check_host(_, _), do: {:error, :forbidden}

  defp check_host_owns_invite(%{host_creator_id: creator_id}, creator_id), do: :ok
  defp check_host_owns_invite(_, _), do: {:error, :forbidden}

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
