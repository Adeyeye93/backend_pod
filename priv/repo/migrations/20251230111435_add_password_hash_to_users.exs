defmodule Pod.Repo.Migrations.AddPasswordHashToUsers do
  use Ecto.Migration

def change do
  alter table(:users) do
  add :hashed_password, :string
  add :password_confirmation, :string  # virtual, won't be in DB
  end
end
end
