defmodule Pod.Podcast do
  # lib/your_app/podcasts.ex
# Context module for podcast operations

  import Ecto.Query
  alias Pod.Repo
  alias Pod.Stream.{LiveStream, GuestInvite}

  # ============= SCHEDULE PODCAST WITH GUESTS =============

  @doc """
  Creates a scheduled podcast and sends invites to guests in ONE transaction.
  Invites can ONLY be sent during podcast creation/scheduling.

  Returns {:ok, live_stream} or {:error, changeset}
  """
  def schedule_podcast_with_guests(creator_id, podcast_attrs, guest_list) do
    Repo.transaction(fn ->
      # Step 1: Create the live stream (scheduled status)
      case create_scheduled_podcast(creator_id, podcast_attrs) do
        {:ok, live_stream} ->
          # Step 2: Send invites to all guests
          case send_guest_invites(live_stream, guest_list, creator_id) do
            {:ok, _invites} ->
              # Reload live stream with associations
              live_stream = Repo.preload(live_stream, :guest_invites)
              {:ok, live_stream}

            {:error, reason} ->
              Repo.rollback(reason)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # ============= CREATE SCHEDULED PODCAST (NO GUESTS YET) =============

  @doc """
  Creates a scheduled podcast without guests.
  Invites CAN be added later during scheduling phase.
  """
  def create_scheduled_podcast(creator_id, attrs) do
    %LiveStream{}
    |> LiveStream.changeset(Map.merge(attrs, %{
      "creator_id" => creator_id,
      "status" => "scheduled"
    }))
    |> Repo.insert()
  end

  # ============= ADD GUESTS TO SCHEDULED PODCAST ONLY =============

  @doc """
  Adds guests to a podcast ONLY if it's still in scheduled status.
  Returns {:ok, [invites]} or {:error, "Cannot add guests to a live/ended podcast"}
  """
  def add_guests_to_scheduled_podcast(live_stream_id, guest_list, host_creator_id) do
    live_stream = Repo.get(LiveStream, live_stream_id)

    # Validate: Can only add guests if podcast is still scheduled
    case live_stream.status do
      "scheduled" ->
        send_guest_invites(live_stream, guest_list, host_creator_id)

      "live" ->
        {:error, "Cannot add guests to a live podcast"}

      "ended" ->
        {:error, "Cannot add guests to an ended podcast"}
    end
  end

  # ============= SEND GUEST INVITES (INTERNAL) =============

  defp send_guest_invites(live_stream, guest_list, host_creator_id) do
    invites =
      guest_list
      |> Enum.map(fn guest_id ->
        %GuestInvite{
          live_stream_id: live_stream.id,
          host_creator_id: host_creator_id,
          guest_creator_id: guest_id,
          status: "pending",
          role: "guest",
          scheduled_start_time: live_stream.scheduled_start_time,
          invite_sent_at: DateTime.utc_now()
        }
      end)

    case Repo.insert_all(GuestInvite, invites, returning: true) do
      {:ok, inserted_invites} -> {:ok, inserted_invites}
      _ -> {:error, "error"}
    end
  end

  # ============= REMOVE GUEST INVITE (BEFORE PODCAST STARTS) =============

  @doc """
  Cancels a guest invite ONLY if the podcast hasn't started yet.
  """
  def cancel_guest_invite(invite_id) do
    invite = Repo.get(GuestInvite, invite_id) |> Repo.preload(:live_stream)

    case invite.live_stream.status do
      "scheduled" ->
        invite
        |> GuestInvite.changeset(%{status: "cancelled"})
        |> Repo.update()

      "live" ->
        {:error, "Cannot cancel invites for a live podcast"}

      "ended" ->
        {:error, "Cannot cancel invites for an ended podcast"}
    end
  end

  # ============= START PODCAST (VALIDATE GUESTS) =============

  @doc """
  Starts a podcast and validates:
  1. At least 1 hour has passed since scheduling
  2. All guests have either accepted or declined
  3. Accepted guests have accepted at least 1 hour before start time

  Returns {:ok, live_stream} or {:error, reason}
  """
  def start_podcast(live_stream_id) do
    live_stream =
      Repo.get(LiveStream, live_stream_id)
      |> Repo.preload(:guest_invites)

    # Validate podcast is scheduled
    case live_stream.status do
      "scheduled" ->
        case validate_podcast_start(live_stream) do
          :ok ->
            live_stream
            |> LiveStream.start_stream_changeset(%{
              status: "live",
              actual_start_time: DateTime.utc_now()
            })
            |> Repo.update()

          {:error, reason} ->
            {:error, reason}
        end

      "live" ->
        {:error, "Podcast is already live"}

      "ended" ->
        {:error, "Podcast has already ended"}
    end
  end

  # ============= VALIDATION LOGIC =============

  defp validate_podcast_start(live_stream) do
    now = DateTime.utc_now()
    scheduled_time = live_stream.scheduled_start_time
    one_hour_before = DateTime.add(scheduled_time, -3600, :second)

    # Check 1: Is it at least 1 hour before scheduled start?
    unless DateTime.compare(now, one_hour_before) in [:gt, :eq] do
       {:error, "Must wait until 1 hour before scheduled start time"}
    end

    # Check 2: Have all guests responded?
    invites = live_stream.guest_invites

    unless Enum.all?(invites, &guest_responded?/1) do
       {:error, "All guests must accept or decline before starting"}
    end

    # Check 3: Have accepted guests accepted at least 1 hour before?
    accepted_invites = Enum.filter(invites, &(&1.status == "accepted"))

    unless Enum.all?(accepted_invites, &accepted_in_time?/1) do
       {:error, "All guests must accept at least 1 hour before podcast starts"}
    end

    :ok
  end

  defp guest_responded?(invite) do
    invite.status in ["accepted", "declined"]
  end

  defp accepted_in_time?(invite) do
    now = DateTime.utc_now()
    scheduled_time = invite.scheduled_start_time
    one_hour_before = DateTime.add(scheduled_time, -3600, :second)

    DateTime.compare(invite.accepted_at, one_hour_before) in [:lt, :eq]
  end

  # ============= GET PODCAST WITH GUESTS =============

  @doc """
  Gets a podcast with all its guest invites and accepted guests.
  """
  def get_podcast_with_guests(live_stream_id) do
    LiveStream
    |> where(id: ^live_stream_id)
    |> preload([:creator, :guest_invites])
    |> Repo.one()
  end

  @doc """
  Gets only accepted guests for a podcast.
  """
  def get_accepted_guests(live_stream_id) do
    GuestInvite
    |> where(live_stream_id: ^live_stream_id, status: "accepted")
    |> preload(:guest_creator)
    |> Repo.all()
  end

  # ============= GUEST ACCEPTS INVITE =============

  @doc """
  Guest accepts an invite to join a podcast.
  Can only accept if podcast is still scheduled.
  """
  def accept_guest_invite(invite_id) do
    invite = Repo.get(GuestInvite, invite_id) |> Repo.preload(:live_stream)

    case invite.live_stream.status do
      "scheduled" ->
        invite
        |> GuestInvite.accept_changeset(%{})
        |> Repo.update()

      "live" ->
        {:error, "Cannot accept invites for a live podcast"}

      "ended" ->
        {:error, "Cannot accept invites for an ended podcast"}
    end
  end

  # ============= GUEST DECLINES INVITE =============

  @doc """
  Guest declines an invite.
  Can decline at any time.
  """
  def decline_guest_invite(invite_id) do
    invite = Repo.get(GuestInvite, invite_id)

    invite
    |> GuestInvite.decline_changeset(%{})
    |> Repo.update()
  end

  # ============= END PODCAST =============

  @doc """
  Ends a live podcast and records final statistics.
  """
  def end_podcast(live_stream_id, stats) do
    Repo.get(LiveStream, live_stream_id)
    |> LiveStream.end_stream_changeset(%{
      status: "ended",
      end_time: DateTime.utc_now(),
      total_viewers: stats["total_viewers"],
      peak_viewers: stats["peak_viewers"],
      avg_watch_time: stats["avg_watch_time"],
      engagement_rate: stats["engagement_rate"]
    })
    |> Repo.update()
  end
end
