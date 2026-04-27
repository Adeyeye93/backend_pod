defmodule PodWeb.GuestInviteController do
  use PodWeb, :controller

  alias Pod.GuestInvites
  alias Pod.Stream, as: StreamContext
  alias Pod.Creators

  # ---------------------------------------------------------------------------
  # GET /api/streams/:id/invites
  # Host views all invites for their stream
  # ---------------------------------------------------------------------------

  def index(conn, %{"stream_id" => stream_id}) do
    with %{} = creator <- get_creator(conn),
         %{} = stream <- StreamContext.get_stream(stream_id),
         :ok <- check_host(stream, creator.id) do
      invites = GuestInvites.list_invites_for_stream(stream_id)
      render(conn, :index, invites: invites)
    else
      nil -> send_resp(conn, 404, "Not found")
      {:error, :forbidden} -> send_resp(conn, 403, "Forbidden")
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/streams/:id/invites
  # Host sends an invite using the guest's invite_key
  # Body: { "invite_key": "abc123..." }
  # ---------------------------------------------------------------------------

  def create(conn, %{"stream_id" => stream_id, "invite_key" => invite_key}) do
  with %{} = creator <- get_creator(conn),
       %{} = stream <- StreamContext.get_stream(stream_id),
       :ok <- check_host(stream, creator.id),
       {:ok, invite} <- GuestInvites.invite(stream, creator.id, invite_key) do
    conn
    |> put_status(:created)
    |> put_view(PodWeb.GuestInviteJSON)
    |> render(:show, invite: invite)
  else
    nil ->
      send_resp(conn, 404, "Stream not found")

    {:error, :forbidden} ->
      send_resp(conn, 403, "Forbidden")

    # ---------- Soft business rule errors (return HTTP 200) ----------
    {:error, :invite_deadline_passed} ->
      json(conn, %{success: false, reason: "invite_deadline_passed"})

    {:error, :guest_cap_reached} ->
      json(conn, %{success: false, reason: "guest_cap_reached"})

    {:error, :invalid_invite_key} ->
      json(conn, %{success: false, reason: "invalid_invite_key"})

    {:error, :cannot_invite_yourself} ->
      json(conn, %{success: false, reason: "cannot_invite_yourself"})

    {:error, :already_invited} ->
      json(conn, %{success: false, reason: "already_invited"})

    # ---------- Hard errors (still 422) ----------
    {:error, :invites_not_available} ->
      json_error(conn, 422, "This stream does not support invites")

    {:error, changeset} ->
      json_error(conn, 422, format_errors(changeset))
  end
end

  # ---------------------------------------------------------------------------
  # GET /api/streams/:id/participants
  # Host views all participants (host and accepted guests) for their stream
  # ---------------------------------------------------------------------------

  def participants(conn, %{"stream_id" => stream_id}) do
    with %{} = creator <- get_creator(conn),
         %{} = stream <- StreamContext.get_stream(stream_id),
         :ok <- check_host(stream, creator.id) do
      host = Creators.get_creator(stream.creator_id)
      accepted_invites = GuestInvites.get_accepted_invites(stream_id)

      guests =
        Enum.map(accepted_invites, fn invite ->
          Creators.get_creator(invite.guest_creator_id)
        end)

      participants = %{
        host: Pod.Stream.CreatorSerializer.serialize(host),
        guests: Enum.map(guests, &Pod.Stream.CreatorSerializer.serialize/1)
      }

      json(conn, %{participants: participants})
    else
      nil -> send_resp(conn, 404, "Not found")
      {:error, :forbidden} -> send_resp(conn, 403, "Forbidden")
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /api/streams/:id/invites/:invite_id/accept
  # Guest accepts their invite
  # ---------------------------------------------------------------------------

  def accept(conn, %{"stream_id" => stream_id, "invite_id" => invite_id}) do
    with %{} = creator <- get_creator(conn),
         %{} = invite <- GuestInvites.get_invite(invite_id),
         :ok <- check_guest(invite, creator.id),
         {:ok, updated} <- GuestInvites.accept(invite) do

      PodWeb.ScheduledStreamChannel.notify_participants_updated(stream_id)
      render(conn, :show, invite: updated)
    else
      nil -> send_resp(conn, 404, "Invite not found")
      {:error, :forbidden} -> send_resp(conn, 403, "Forbidden")
      {:error, :already_responded} -> json_error(conn, 422, "Already responded to this invite")
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /api/streams/:id/invites/:invite_id/decline
  # Guest declines their invite
  # ---------------------------------------------------------------------------

  def decline(conn, %{"stream_id" => stream_id, "invite_id" => invite_id}) do
    with %{} = creator <- get_creator(conn),
         %{} = invite <- GuestInvites.get_invite(invite_id),
         :ok <- check_guest(invite, creator.id),
         {:ok, updated} <- GuestInvites.decline(invite) do

      PodWeb.ScheduledStreamChannel.notify_participants_updated(stream_id)
      render(conn, :show, invite: updated)
    else
      nil -> send_resp(conn, 404, "Invite not found")
      {:error, :forbidden} -> send_resp(conn, 403, "Forbidden")
      {:error, :already_responded} -> json_error(conn, 422, "Already responded to this invite")
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/streams/:id/invites/:invite_id
  # Host cancels an invite
  # ---------------------------------------------------------------------------

  def delete(conn, %{"stream_id" => _stream_id, "invite_id" => invite_id}) do
    with %{} = creator <- get_creator(conn),
         %{} = invite <- GuestInvites.get_invite(invite_id),
         :ok <- check_host_owns_invite(invite, creator.id),
         {:ok, _} <- GuestInvites.cancel(invite) do
      send_resp(conn, 204, "")
    else
      nil -> send_resp(conn, 404, "Invite not found")
      {:error, :forbidden} -> send_resp(conn, 403, "Forbidden")
      {:error, :cannot_cancel} -> json_error(conn, 422, "Only pending invites can be cancelled")
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/creators/me/invite_key
  # Creator fetches their own invite key to share manually
  # ---------------------------------------------------------------------------

  def my_invite_key(conn, _params) do
    case get_creator(conn) do
      nil ->
        send_resp(conn, 404, "Creator profile not found")

      creator ->
        json(conn, %{invite_key: creator.invite_key})
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/creators/me/pending_invites
  # Creator sees invites they have received
  # ---------------------------------------------------------------------------

  def pending_invites(conn, _params) do
    case get_creator(conn) do
      nil ->
        send_resp(conn, 404, "Creator profile not found")

      creator ->
        invites = GuestInvites.list_pending_invites_for_creator(creator.id)
        render(conn, :index, invites: invites)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_creator(conn) do
    user = Guardian.Plug.current_resource(conn)
    Creators.get_creator_by_user(user.id)
  end

  defp check_host(%{creator_id: creator_id}, creator_id), do: :ok
  defp check_host(_, _), do: {:error, :forbidden}

  defp check_guest(%{guest_creator_id: creator_id}, creator_id), do: :ok
  defp check_guest(_, _), do: {:error, :forbidden}

  defp check_host_owns_invite(%{host_creator_id: creator_id}, creator_id), do: :ok
  defp check_host_owns_invite(_, _), do: {:error, :forbidden}

  defp json_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end

# ---------------------------------------------------------------------------
# Add these routes to your router.ex inside the jwt_authenticated scope
# ---------------------------------------------------------------------------

# Inside scope "/api", PodWeb, as: :api do
#   pipe_through [:api, :jwt_authenticated]
#
#   # Invite key — creator profile
#   get  "/creators/me/invite_key",      GuestInviteController, :my_invite_key
#   get  "/creators/me/pending_invites", GuestInviteController, :pending_invites
#
#   # Stream invites
#   get    "/streams/:stream_id/invites",                      GuestInviteController, :index
#   post   "/streams/:stream_id/invites",                      GuestInviteController, :create
#   put    "/streams/:stream_id/invites/:invite_id/accept",    GuestInviteController, :accept
#   put    "/streams/:stream_id/invites/:invite_id/decline",   GuestInviteController, :decline
#   delete "/streams/:stream_id/invites/:invite_id",           GuestInviteController, :delete
