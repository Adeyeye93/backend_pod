defmodule Pod.Repo.Migrations.CreateInterests do
  use Ecto.Migration

  def change do
    create table(:interests) do
      add :name, :string
      add :description, :text
      
      timestamps(type: :utc_datetime)
    end

    create unique_index(:interests, [:name])
  end
end
