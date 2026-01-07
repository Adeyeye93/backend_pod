defmodule Pod.Accounts.UserInterest do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_interests" do

     belongs_to :user, Pod.Accounts.User
    belongs_to :interest, Pod.Interests.Interest

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user_interest, attrs) do
    user_interest
    |> cast(attrs, [])
    |> validate_required([])
  end
end
