defmodule Pod.Interests.Interest do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:id, :name, :description]}
  schema "interests" do
    field :name, :string
    field :description, :string

    has_many :user_interests, Pod.Accounts.UserInterest
    has_many :users, through: [:user_interests, :user]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(interest, attrs) do
    interest
    |> cast(attrs, [:name, :description])
    |> validate_required([:name, :description])
  end
end
