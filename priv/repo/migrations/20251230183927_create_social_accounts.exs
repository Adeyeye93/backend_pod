defmodule Pod.Repo.Migrations.CreateSocialAccounts do
  use Ecto.Migration

  def change do
  create table(:social_accounts) do
    add :provider, :string, null: false
    add :provider_id, :string, null: false
    add :provider_email, :string
    add :provider_name, :string
    add :user_id, references(:users, on_delete: :delete_all), null: false
    timestamps()
  end

  create unique_index(:social_accounts, [:provider, :provider_id])
end
end
