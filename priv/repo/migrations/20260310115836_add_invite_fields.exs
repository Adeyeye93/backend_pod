defmodule Pod.Repo.Migrations.AddInviteFields do
 use Ecto.Migration

  def change do
    # Add invite_key to creators — shared manually outside the app
    # Refreshes immediately when a guest accepts an invite
    alter table(:creators) do
      add :invite_key, :string
    end

    # Add invite_deadline to live_streams — calculated at schedule time
    # as scheduled_start_time - 1 hour. Invites are blocked after this passes.
    alter table(:live_streams) do
      add :invite_deadline, :utc_datetime
    end

    # Unique constraint on invite_key — no two creators can share a key
    create unique_index(:creators, [:invite_key])
  end
end
