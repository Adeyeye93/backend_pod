defmodule Pod.GuestInvites do
  @moduledoc """
  The GuestInvites context.

  Handles inviting guest creators to join a live stream — sending invites,
  accepting, declining, and checking whether a guest is allowed to join.

  The flow is:
    1. Host creator schedules a stream and invites a guest via invite/2
    2. Guest receives a notification and calls accept/1 or decline/1
    3. When the stream starts, can_join?/1 is used to gate access
  """

  import Ecto.Query
  alias Pod.Repo
  alias Pod.Stream.GuestInvite

  # ---------------------------------------------------------------------------
  # Sending invites
  # ---------------------------------------------------------------------------

  @doc """
  Sends an invite from a host creator to a guest creator for a live stream.

  attrs must include:
    - live_stream_id
    - host_creator_id
    - guest_creator_id
    - scheduled_start_time
    - role ("guest" or "co-host")
    - message (optional)
  """
  def invite(attrs) do
    %GuestInvite{}
    |> GuestInvite.changeset(attrs)
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Responding to invites
  # ---------------------------------------------------------------------------

  @doc """
  Accepts a pending invite.
  Returns {:error, :already_responded} if the invite is not pending.
  """
  def accept(%GuestInvite{status: "pending"} = invite) do
    invite
    |> GuestInvite.accept_changeset(%{})
    |> Repo.update()
  end

  def accept(%GuestInvite{}), do: {:error, :already_responded}

  @doc """
  Declines a pending invite.
  Returns {:error, :already_responded} if the invite is not pending.
  """
  def decline(%GuestInvite{status: "pending"} = invite) do
    invite
    |> GuestInvite.decline_changeset(%{})
    |> Repo.update()
  end

  def decline(%GuestInvite{}), do: {:error, :already_responded}

  @doc """
  Cancels an invite — called by the host if they change their mind.
  Only pending invites can be cancelled.
  """
  def cancel(%GuestInvite{status: "pending"} = invite) do
    invite
    |> GuestInvite.changeset(%{status: "cancelled"})
    |> Repo.update()
  end

  def cancel(%GuestInvite{}), do: {:error, :cannot_cancel}

  @doc """
  Records the time a guest actually joined the stream.
  Called when the guest's client connects to the broadcast.
  """
  def record_join(%GuestInvite{} = invite) do
    invite
    |> GuestInvite.changeset(%{
      joined_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Fetching invites
  # ---------------------------------------------------------------------------

  @doc """
  Gets a single invite by ID.
  """
  def get_invite(id), do: Repo.get(GuestInvite, id)

  @doc """
  Gets all invites sent by a host creator for a specific stream.
  Useful for showing the host who they have invited.
  """
  def list_invites_for_stream(live_stream_id) do
    GuestInvite
    |> where([i], i.live_stream_id == ^live_stream_id)
    |> preload([:host_creator, :guest_creator])
    |> Repo.all()
  end

  @doc """
  Gets all pending invites received by a guest creator.
  Used to show a creator their incoming invitations.
  """
  def list_pending_invites_for_creator(guest_creator_id) do
    GuestInvite
    |> where([i], i.guest_creator_id == ^guest_creator_id)
    |> where([i], i.status == "pending")
    |> preload([:live_stream, :host_creator])
    |> Repo.all()
  end

  @doc """
  Gets the accepted invite for a guest on a specific stream.
  Used to verify a guest is allowed to participate before they join.
  """
  def get_accepted_invite(live_stream_id, guest_creator_id) do
    GuestInvite
    |> where([i], i.live_stream_id == ^live_stream_id)
    |> where([i], i.guest_creator_id == ^guest_creator_id)
    |> where([i], i.status == "accepted")
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
  # Access control
  # ---------------------------------------------------------------------------

  @doc """
  Checks whether a guest is allowed to join a stream right now.

  Delegates to GuestInvite.can_start_stream?/1 which checks:
    - invite is accepted
    - current time is within 1 hour of the scheduled start time

  Returns true or false.
  """
  def can_join?(live_stream_id, guest_creator_id) do
    case get_accepted_invite(live_stream_id, guest_creator_id) do
      nil -> false
      invite -> GuestInvite.can_start_stream?(invite)
    end
  end
end
