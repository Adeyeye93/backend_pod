defmodule Pod.Follows.Follow do
  use Pod.Schema
  import Ecto.Changeset

  schema "follows" do
    belongs_to :follower, Pod.Accounts.User
    belongs_to :creator, Pod.Stream.Creator

    timestamps(type: :utc_datetime)
  end

  def changeset(follow, attrs) do
    follow
    |> cast(attrs, [:follower_id, :creator_id])
    |> validate_required([:follower_id, :creator_id])
    |> unique_constraint([:follower_id, :creator_id],
        name: :follows_follower_id_creator_id_index,
        message: "already following this creator"
       )
    |> assoc_constraint(:follower)
    |> assoc_constraint(:creator)
  end
end
