defmodule Pod.ListeningHistory.ListeningHistory do
  use Pod.Schema
  import Ecto.Changeset

  schema "listening_history" do
    belongs_to :user, Pod.Accounts.User
    belongs_to :live_stream, Pod.Stream.LiveStream

    field :progress_seconds, :integer, default: 0
    field :completed, :boolean, default: false
    field :last_listened_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(history, attrs) do
    history
    |> cast(attrs, [:user_id, :live_stream_id, :progress_seconds, :completed, :last_listened_at])
    |> validate_required([:user_id, :live_stream_id, :last_listened_at])
    |> validate_number(:progress_seconds, greater_than_or_equal_to: 0)
    |> unique_constraint([:user_id, :live_stream_id],
        name: :listening_history_user_id_live_stream_id_index,
        message: "progress record already exists"
       )
    |> assoc_constraint(:user)
    |> assoc_constraint(:live_stream)
  end
end
