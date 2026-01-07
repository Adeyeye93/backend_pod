defmodule Pod.Repo.Migrations.CreateUserInterests do
  use Ecto.Migration

  def change do
    create table(:user_interests) do
      add :user_id, references(:users, on_delete: :nothing)
      add :interest_id, references(:interests, on_delete: :nothing)

      timestamps(type: :utc_datetime)
    end

    create index(:user_interests, [:user_id])
    create index(:user_interests, [:interest_id])
  end
end
