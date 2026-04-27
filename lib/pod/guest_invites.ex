# defmodule Pod.GuestInvites do
#   @moduledoc """
#   The GuestInvites context.

#   Handles inviting guest creators to join a live stream — sending invites,
#   accepting, declining, and checking whether a guest is allowed to join.

#   The flow is:
#     1. Host creator schedules a stream and invites a guest via invite/2
#     2. Guest receives a notification and calls accept/1 or decline/1
#     3. When the stream starts, can_join?/1 is used to gate access
#   """

#   import Ecto.Query
#   alias Pod.Repo
#   alias Pod.Stream.GuestInvite

#   # ---------------------------------------------------------------------------
#   # Sending invites
#   # ---------------------------------------------------------------------------

#   @doc """
#   Sends an invite from a host creator to a guest creator for a live stream.

#   attrs must include:
#     - live_stream_id
#     - host_creator_id
#     - guest_creator_id
#     - scheduled_start_time
#     - role ("guest" or "co-host")
#     - message (optional)
#   """
#   def invite(attrs) do
#     %GuestInvite{}
#     |> GuestInvite.changeset(attrs)
#     |> Repo.insert()
#   end

#   # ---------------------------------------------------------------------------
#   # Responding to invites
#   # ---------------------------------------------------------------------------

#   @doc """
#   Accepts a pending invite.
#   Returns {:error, :already_responded} if the invite is not pending.
#   """
#   def accept(%GuestInvite{status: "pending"} = invite) do
#     invite
#     |> GuestInvite.accept_changeset(%{})
#     |> Repo.update()
#   end

#   def accept(%GuestInvite{}), do: {:error, :already_responded}

#   @doc """
#   Declines a pending invite.
#   Returns {:error, :already_responded} if the invite is not pending.
#   """
#   def decline(%GuestInvite{status: "pending"} = invite) do
#     invite
#     |> GuestInvite.decline_changeset(%{})
#     |> Repo.update()
#   end

#   def decline(%GuestInvite{}), do: {:error, :already_responded}

#   @doc """
#   Cancels an invite — called by the host if they change their mind.
#   Only pending invites can be cancelled.
#   """
#   def cancel(%GuestInvite{status: "pending"} = invite) do
#     invite
#     |> GuestInvite.changeset(%{status: "cancelled"})
#     |> Repo.update()
#   end

#   def cancel(%GuestInvite{}), do: {:error, :cannot_cancel}

#   @doc """
#   Records the time a guest actually joined the stream.
#   Called when the guest's client connects to the broadcast.
#   """
#   def record_join(%GuestInvite{} = invite) do
#     invite
#     |> GuestInvite.changeset(%{
#       joined_at: DateTime.utc_now() |> DateTime.truncate(:second)
#     })
#     |> Repo.update()
#   end

#   # ---------------------------------------------------------------------------
#   # Fetching invites
#   # ---------------------------------------------------------------------------

#   @doc """
#   Gets a single invite by ID.
#   """
#   def get_invite(id), do: Repo.get(GuestInvite, id)

#   @doc """
#   Gets all invites sent by a host creator for a specific stream.
#   Useful for showing the host who they have invited.
#   """
#   def list_invites_for_stream(live_stream_id) do
#     GuestInvite
#     |> where([i], i.live_stream_id == ^live_stream_id)
#     |> preload([:host_creator, :guest_creator])
#     |> Repo.all()
#   end

#   @doc """
#   Gets all pending invites received by a guest creator.
#   Used to show a creator their incoming invitations.
#   """
#   def list_pending_invites_for_creator(guest_creator_id) do
#     GuestInvite
#     |> where([i], i.guest_creator_id == ^guest_creator_id)
#     |> where([i], i.status == "pending")
#     |> preload([:live_stream, :host_creator])
#     |> Repo.all()
#   end

#   @doc """
#   Gets the accepted invite for a guest on a specific stream.
#   Used to verify a guest is allowed to participate before they join.
#   """
#   def get_accepted_invite(live_stream_id, guest_creator_id) do
#     GuestInvite
#     |> where([i], i.live_stream_id == ^live_stream_id)
#     |> where([i], i.guest_creator_id == ^guest_creator_id)
#     |> where([i], i.status == "accepted")
#     |> Repo.one()
#   end

#   # ---------------------------------------------------------------------------
#   # Access control
#   # ---------------------------------------------------------------------------

#   @doc """
#   Checks whether a guest is allowed to join a stream right now.

#   Delegates to GuestInvite.can_start_stream?/1 which checks:
#     - invite is accepted
#     - current time is within 1 hour of the scheduled start time

#   Returns true or false.
#   """
#   def can_join?(live_stream_id, guest_creator_id) do
#     case get_accepted_invite(live_stream_id, guest_creator_id) do
#       nil -> false
#       invite -> GuestInvite.can_start_stream?(invite)
#     end
#   end
# end

defmodule Pod.GuestInvites do
  @moduledoc """
  Handles inviting guest creators to join a live stream.

  ## Invite flow

    1. Host gets guest's invite_key out of band (guest shares it manually)
    2. Host calls invite/3 with the stream, their creator, and the guest's invite_key
    3. Context validates: deadline not passed, guest cap not reached, key is valid
    4. Guest receives a notification and calls accept/1 or decline/1
    5. On accept — guest's invite_key is refreshed immediately (one-time use)
    6. When stream starts, can_join?/2 gates access

  ## Guest cap

  Maximum 4 guests per stream (5 total participants including host).

  ## Invite deadline

  Stored on LiveStream as invite_deadline = scheduled_start_time - 1 hour.
  Calculated at schedule creation time. Once the deadline passes no new
  invites can be sent regardless of how much time remains before the stream.
  """

  import Ecto.Query
  alias Pod.Repo
  alias Pod.Stream.GuestInvite
  alias Pod.Stream.LiveStream
  alias Pod.Creators

  @max_guests 4

  # ---------------------------------------------------------------------------
  # Sending invites
  # ---------------------------------------------------------------------------

  @doc """
  Sends an invite from a host creator to a guest creator identified by their invite_key.

  Validates:
    - invite_deadline has not passed
    - stream has not already reached the 4 guest cap
    - invite_key belongs to a real creator
    - host is not inviting themselves
    - guest has not already been invited to this stream

  Returns {:ok, invite} or {:error, reason}
  """
  def invite(%LiveStream{} = stream, host_creator_id, guest_invite_key) do
    IO.inspect(
      "Inviting guest with key #{guest_invite_key} to stream #{stream.id} by host #{host_creator_id}"
    )

    with :ok <- taps(check_invite_deadline(stream), "deadline"),
         :ok <- taps(check_guest_cap(stream.id), "guest_cap"),
         {:ok, guest_creator} <-
           taps(find_creator_by_invite_key(guest_invite_key), "find_creator"),
         :ok <- taps(check_not_self_invite(host_creator_id, guest_creator.id), "self_invite"),
         :ok <- taps(check_not_already_invited(stream.id, guest_creator.id), "already") do
      scheduled =
        stream.scheduled_start_time
        |> DateTime.truncate(:second)

      %GuestInvite{}
      |> GuestInvite.changeset(%{
        live_stream_id: stream.id,
        host_creator_id: host_creator_id,
        guest_creator_id: guest_creator.id,
        scheduled_start_time: scheduled,
        role: "guest"
      })
      |> Repo.insert()
    end
  end

  defp taps(result, label) do
    IO.inspect({label, result})
    result
  end

  # ---------------------------------------------------------------------------
  # Responding to invites
  # ---------------------------------------------------------------------------

  @doc """
  Accepts a pending invite and immediately refreshes the guest's invite_key.
  The invite_key is single-use — once accepted it rotates so the same key
  cannot be used to invite the same creator again.
  """
  def accept(%GuestInvite{status: "pending"} = invite) do
    Repo.transaction(fn ->
      # Update invite status
      updated_invite =
        invite
        |> GuestInvite.accept_changeset(%{})
        |> Repo.update!()

      # Refresh the guest's invite key immediately — one-time use
      Creators.refresh_invite_key(invite.guest_creator_id)

      updated_invite
    end)
  end

  def accept(%GuestInvite{}), do: {:error, :already_responded}

  @doc """
  Declines a pending invite.
  The invite_key is NOT refreshed on decline — only on accept.
  """
  def decline(%GuestInvite{status: "pending"} = invite) do
    invite
    |> GuestInvite.decline_changeset(%{})
    |> Repo.update()
  end

  def decline(%GuestInvite{}), do: {:error, :already_responded}

  @doc """
  Cancels a pending invite — called by the host if they change their mind.
  """
  def cancel(%GuestInvite{status: "pending"} = invite) do
    invite
    |> GuestInvite.changeset(%{status: "cancelled"})
    |> Repo.update()
  end

  def cancel(%GuestInvite{}), do: {:error, :cannot_cancel}

  @doc """
  Records the time a guest actually joined the stream.
  Called when the guest's WebRTC client connects.
  """
  def record_join(%GuestInvite{} = invite) do
    invite
    |> GuestInvite.changeset(%{joined_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Fetching invites
  # ---------------------------------------------------------------------------

  def get_invite(id), do: Repo.get(GuestInvite, id)

  def list_invites_for_stream(live_stream_id) do
    GuestInvite
    |> where([i], i.live_stream_id == ^live_stream_id)
    |> preload([:host_creator, :guest_creator])
    |> Repo.all()
  end

  def list_pending_invites_for_creator(guest_creator_id) do
    GuestInvite
    |> where([i], i.guest_creator_id == ^guest_creator_id)
    |> where([i], i.status == "pending")
    |> preload([:live_stream, :host_creator])
    |> Repo.all()
  end

  def get_accepted_invites(stream_id) do
    GuestInvite
    |> where([i], i.live_stream_id == ^stream_id)
    |> where([i], i.status == "accepted")
    |> Repo.all()
  end

  def get_accepted_invite(live_stream_id, guest_creator_id) do
    GuestInvite
    |> where([i], i.live_stream_id == ^live_stream_id)
    |> where([i], i.guest_creator_id == ^guest_creator_id)
    |> where([i], i.status == "accepted")
    |> Repo.one()
  end

  #   def get_accepted_invite(stream_id, host_creator_id) do
  #   from(g in GuestInvite,
  #     where: g.live_stream_id == ^stream_id,
  #     where: g.host_creator_id == ^host_creator_id,
  #     where: g.status == "accepted"
  #   )
  #   |> Repo.all()
  # end

  # ---------------------------------------------------------------------------
  # Access control
  # ---------------------------------------------------------------------------

  def can_join?(live_stream_id, guest_creator_id) do
    case get_accepted_invite(live_stream_id, guest_creator_id) do
      nil -> false
      invite -> GuestInvite.can_start_stream?(invite)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — validations
  # ---------------------------------------------------------------------------

  defp check_invite_deadline(%LiveStream{invite_deadline: nil}) do
    # No deadline set — stream was scheduled without one (immediate streams)
    {:error, :invites_not_available}
  end

  defp check_invite_deadline(%LiveStream{invite_deadline: deadline}) do
    if DateTime.compare(DateTime.utc_now(), deadline) == :lt do
      :ok
    else
      {:error, :invite_deadline_passed}
    end
  end

  defp check_guest_cap(live_stream_id) do
    count =
      GuestInvite
      |> where([i], i.live_stream_id == ^live_stream_id)
      |> where([i], i.status in ["pending", "accepted"])
      |> Repo.aggregate(:count, :id)

    if count < @max_guests do
      :ok
    else
      {:error, :guest_cap_reached}
    end
  end

  defp find_creator_by_invite_key(invite_key) do
    case Creators.get_creator_by_invite_key(invite_key) do
      nil -> {:error, :invalid_invite_key}
      creator -> {:ok, creator}
    end
  end

  defp check_not_self_invite(host_creator_id, guest_creator_id) do
    if host_creator_id == guest_creator_id do
      {:error, :cannot_invite_yourself}
    else
      :ok
    end
  end

  defp check_not_already_invited(live_stream_id, guest_creator_id) do
    existing =
      GuestInvite
      |> where([i], i.live_stream_id == ^live_stream_id)
      |> where([i], i.guest_creator_id == ^guest_creator_id)
      |> where([i], i.status in ["pending", "accepted"])
      |> Repo.one()

    if is_nil(existing) do
      :ok
    else
      {:error, :already_invited}
    end
  end
end
