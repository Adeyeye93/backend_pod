defmodule Pod.Repo.Migrations.CreateMoods do
  use Ecto.Migration

 def change do
    create table(:moods) do
      add :name, :string, null: false
      add :description, :text
      add :icon, :string
      add :color, :string, default: "#000000"
      add :is_active, :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    # Create unique index on name
    create unique_index(:moods, [:name])
  end
end
