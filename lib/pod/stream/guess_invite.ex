defmodule Pod.Stream.GuestInvite do
  use Pod.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "guest_invites" do
    # pending, accepted, declined, cancelled
    field :status, :string, default: "pending"
    # guest, co-host
    field :role, :string, default: "guest"
    field :message, :string

    # Timestamps for tracking
    field :invite_sent_at, :utc_datetime
    field :accepted_at, :utc_datetime
    field :declined_at, :utc_datetime
    field :joined_at, :utc_datetime

    # Scheduled time (for validation)
    field :scheduled_start_time, :utc_datetime

    # Relationships
    belongs_to :live_stream, Pod.Stream.LiveStream
    belongs_to :host_creator, Pod.Stream.Creator, foreign_key: :host_creator_id
    belongs_to :guest_creator, Pod.Stream.Creator, foreign_key: :guest_creator_id

    timestamps()
  end

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [
      :live_stream_id,
      :host_creator_id,
      :guest_creator_id,
      :status,
      :role,
      :message,
      :invite_sent_at,
      :scheduled_start_time
    ])
    |> validate_required([
      :live_stream_id,
      :host_creator_id,
      :guest_creator_id,
      :scheduled_start_time
    ])
    |> validate_inclusion(:status, ["pending", "accepted", "declined", "cancelled"])
    |> validate_inclusion(:role, ["guest", "co-host"])
    |> unique_constraint([:live_stream_id, :guest_creator_id])
    |> assoc_constraint(:live_stream)
    |> assoc_constraint(:host_creator)
    |> assoc_constraint(:guest_creator)
    |> set_invite_sent_at()
  end

  def accept_changeset(invite, _attrs) do
    invite
    |> cast(%{status: "accepted", accepted_at: DateTime.utc_now()}, [:status, :accepted_at])
  end

  def decline_changeset(invite, _attrs) do
    invite
    |> cast(%{status: "declined", declined_at: DateTime.utc_now()}, [:status, :declined_at])
  end

  defp set_invite_sent_at(changeset) do
    if get_field(changeset, :invite_sent_at) do
      changeset
    else
      put_change(changeset, :invite_sent_at, DateTime.utc_now())
    end
  end

  def can_start_stream?(invite) do
    with {:accepted, true} <- {:accepted, invite.status == "accepted"},
         {:time_passed, true} <- {
           :time_passed,
           DateTime.diff(DateTime.utc_now(), invite.scheduled_start_time, :second) >= -3600
         } do
      true
    else
      _ -> false
    end
  end
end
