defmodule Pod.Stream.Creator do
  use Pod.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "creators" do
    field :channel_id, :binary_id
    field :name, :string
    field :avatar, :string
    field :bio, :string
    field :follower_count, :integer, default: 0
    field :is_active, :boolean, default: true

    # User relationship - UPDATED
    belongs_to :user, Pod.Accounts.User, type: :binary_id

    # Podcast relationships
    has_many :live_streams, Pod.Stream.LiveStream, foreign_key: :creator_id
    has_many :sent_invites, Pod.Stream.GuestInvite, foreign_key: :host_creator_id
    has_many :received_invites, Pod.Stream.GuestInvite, foreign_key: :guest_creator_id

    timestamps()
  end

  def changeset(creator, attrs) do
    creator
    |> cast(attrs, [:user_id, :name, :avatar, :bio, :follower_count, :is_active])
    |> put_channel_id()
    |> validate_required([:user_id, :channel_id])
    |> unique_constraint(:user_id)
    |> unique_constraint(:channel_id)
    |> assoc_constraint(:user)
  end

  defp put_channel_id(%Ecto.Changeset{data: %{channel_id: nil}} = cs) do
    put_change(cs, :channel_id, Ecto.UUID.generate())
  end

  defp put_channel_id(cs), do: cs

  def update_changeset(creator, attrs) do
    creator
    |> cast(attrs, [:name, :avatar, :bio, :follower_count, :is_active])
    |> validate_required([:name])
  end
end
