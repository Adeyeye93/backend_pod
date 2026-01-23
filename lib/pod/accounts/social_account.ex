defmodule Pod.Accounts.SocialAccount do
  use Pod.Schema
  import Ecto.Changeset

  schema "social_accounts" do
    field :provider, :string  # "google" or "apple"
    field :provider_id, :string  # unique ID from provider
    field :provider_email, :string
    field :provider_name, :string
    belongs_to :user, Pod.Accounts.User
    timestamps()
  end

  @doc false
  def changeset(social_account, attrs) do
    social_account
    |> cast(attrs, [:provider, :provider_id, :provider_email, :provider_name, :user_id])
    |> validate_required([:provider, :provider_id, :user_id])
    |> unique_constraint([:provider, :provider_id], message: "already linked to another account")
  end
end
