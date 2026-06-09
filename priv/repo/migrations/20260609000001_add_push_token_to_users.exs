defmodule Pod.Repo.Migrations.AddPushTokenToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :push_token, :string
    end
  end
end
