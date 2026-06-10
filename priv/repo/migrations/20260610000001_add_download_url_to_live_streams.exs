defmodule Pod.Repo.Migrations.AddDownloadUrlToLiveStreams do
  use Ecto.Migration

  def change do
    alter table(:live_streams) do
      add :download_url, :string
    end
  end
end
