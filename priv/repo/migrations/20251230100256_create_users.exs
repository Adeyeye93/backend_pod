defmodule Pod.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string
      add :username, :string
      add :password, :string
      add :avatar_url, :string
      add :bio, :text
      add :am_a_creator, :boolean

      timestamps(type: :utc_datetime)
    end
end
end
