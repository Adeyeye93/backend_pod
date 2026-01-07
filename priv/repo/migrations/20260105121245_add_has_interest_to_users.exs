defmodule Pod.Repo.Migrations.AddHasInterestToUsers do
  use Ecto.Migration

    def change do
      alter table(:users) do
        add :has_interest, :boolean, default: false
        add :interests_selected_at, :naive_datetime
      end
    end
  end
