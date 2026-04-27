defmodule Pod.Repo.Migrations.AddSegmentFieldsToLiveStreams do
  use Ecto.Migration

  def change do
    alter table(:live_streams) do
      add :segment_count,    :integer, default: 0,    null: false
      add :archive_path,     :string
      add :duration_seconds, :integer, default: 0,    null: false
    end
  end
end
