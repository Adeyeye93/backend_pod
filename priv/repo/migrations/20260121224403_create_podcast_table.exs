defmodule Pod.Repo.Migrations.CreatePodcastTable do
  use Ecto.Migration

  def change do
    # Creators table - UPDATED: user_id is FK not just a field
    create table(:creators, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users), null: false
      add :channel_id, :binary_id, null: false
      add :name, :string, null: true
      add :avatar, :string
      add :bio, :text
      add :follower_count, :integer, default: 0
      add :is_active, :boolean, default: true
      timestamps()
    end

    create unique_index(:creators, [:user_id])
    create unique_index(:creators, [:channel_id])

    # Live streams table
    create table(:live_streams, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :creator_id, references(:creators, type: :binary_id), null: false
      add :channel_id, :binary_id, null: false
      add :title, :string, null: false
      add :description, :text
      add :category, :string, null: false
      add :status, :string, default: "scheduled"
      add :is_private, :boolean, default: false
      add :allow_comments, :boolean, default: true
      add :record_stream, :boolean, default: true
      add :audio_quality, :string, default: "high"
      add :sample_rate, :integer, default: 48000
      add :tags, {:array, :string}, default: []
      add :thumbnail, :string
      add :language, :string, default: "en"
      add :age_restriction, :integer, default: 0
      add :content_warning, :string
      add :rtmp_url, :string
      add :stream_key, :string
      add :notify_followers, :boolean, default: true
      add :notify_subscribers, :boolean, default: true
      add :scheduled_start_time, :utc_datetime, null: false
      add :actual_start_time, :utc_datetime
      add :end_time, :utc_datetime
      add :viewer_count, :integer, default: 0
      add :total_viewers, :integer, default: 0
      add :avg_watch_time, :string
      add :peak_viewers, :integer, default: 0
      add :engagement_rate, :float

      timestamps()
    end

    create index(:live_streams, [:creator_id])
    create index(:live_streams, [:status])
    create index(:live_streams, [:scheduled_start_time])

    # Guest invites table
    create table(:guest_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :live_stream_id, references(:live_streams, type: :binary_id), null: false
      add :host_creator_id, references(:creators, type: :binary_id), null: false
      add :guest_creator_id, references(:creators, type: :binary_id), null: false
      add :status, :string, default: "pending"
      add :role, :string, default: "guest"
      add :message, :text
      add :invite_sent_at, :utc_datetime
      add :accepted_at, :utc_datetime
      add :declined_at, :utc_datetime
      add :joined_at, :utc_datetime
      add :scheduled_start_time, :utc_datetime, null: false

      timestamps()
    end

    create index(:guest_invites, [:live_stream_id])
    create index(:guest_invites, [:host_creator_id])
    create index(:guest_invites, [:guest_creator_id])
    create index(:guest_invites, [:status])
    create unique_index(:guest_invites, [:live_stream_id, :guest_creator_id])

    # Stream comments table
    create table(:stream_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :live_stream_id, references(:live_streams, type: :binary_id), null: false
      add :creator_id, references(:creators, type: :binary_id), null: false
      add :text, :text, null: false
      add :likes, :integer, default: 0

      timestamps()
    end

    create index(:stream_comments, [:live_stream_id])
    create index(:stream_comments, [:creator_id])
  end
end
