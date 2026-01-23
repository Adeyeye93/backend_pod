defmodule Pod.Stream.LiveStream do
  use Pod.Schema
  import Ecto.Changeset

  schema "live_streams" do
    field :title, :string
    field :description, :string
    field :category, :string
    field :creator_id, :binary_id
    field :channel_id, :binary_id
    # scheduled, live, ended
    field :status, :string, default: "scheduled"
    field :is_private, :boolean, default: false
    field :allow_comments, :boolean, default: true
    field :record_stream, :boolean, default: true
    # low, medium, high
    field :audio_quality, :string, default: "high"
    field :sample_rate, :integer, default: 48000

    # Stream metadata
    field :tags, {:array, :string}, default: []
    field :thumbnail, :string
    field :language, :string, default: "en"
    # 0, 13, 18, 21
    field :age_restriction, :integer, default: 0
    field :content_warning, :string

    # Stream URLs
    field :rtmp_url, :string
    field :stream_key, :string

    # Notifications
    field :notify_followers, :boolean, default: true
    field :notify_subscribers, :boolean, default: true

    # Timing
    field :scheduled_start_time, :utc_datetime
    field :actual_start_time, :utc_datetime
    field :end_time, :utc_datetime

    # Stream stats
    field :viewer_count, :integer, default: 0
    field :total_viewers, :integer, default: 0
    field :avg_watch_time, :string
    field :peak_viewers, :integer, default: 0
    field :engagement_rate, :float

    # belongs_to :creator, Pod.Stream.Creator, type: :binary_id
    has_many :guest_invites, Pod.Stream.GuestInvite, foreign_key: :live_stream_id
    has_many :guests, through: [:guest_invites, :guest_creator]
    has_many :comments, Pod.Stream.StreamComment, foreign_key: :live_stream_id

    timestamps()
  end

  def changeset(stream, attrs) do
    stream
    |> cast(attrs, [
      :title,
      :description,
      :category,
      :creator_id,
      :channel_id,
      :status,
      :is_private,
      :allow_comments,
      :record_stream,
      :audio_quality,
      :sample_rate,
      :tags,
      :thumbnail,
      :language,
      :age_restriction,
      :content_warning,
      :rtmp_url,
      :stream_key,
      :notify_followers,
      :notify_subscribers,
      :scheduled_start_time,
      :actual_start_time,
      :end_time,
      :viewer_count,
      :total_viewers,
      :avg_watch_time,
      :peak_viewers,
      :engagement_rate
    ])
    |> validate_required([:title, :category, :creator_id, :channel_id, :scheduled_start_time])
    |> validate_inclusion(:status, ["scheduled", "live", "ended"])
    |> validate_inclusion(:audio_quality, ["low", "medium", "high"])
  end

  def start_stream_changeset(stream, attrs) do
    stream
    |> cast(attrs, [:status, :actual_start_time, :rtmp_url, :stream_key])
    |> validate_inclusion(:status, ["live"])
  end

  def end_stream_changeset(stream, attrs) do
    stream
    |> cast(attrs, [
      :status,
      :end_time,
      :total_viewers,
      :peak_viewers,
      :avg_watch_time,
      :engagement_rate
    ])
    |> validate_inclusion(:status, ["ended"])
  end
end
