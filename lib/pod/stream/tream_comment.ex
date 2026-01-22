defmodule Pod.Stream.StreamComment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "stream_comments" do
    field :live_stream_id, :binary_id
    field :creator_id, :binary_id
    field :text, :string
    field :likes, :integer, default: 0

    # belongs_to :live_stream, Pod.Stream.LiveStream, type: :binary_id
    # belongs_to :creator, Pod.Stream.Creator, type: :binary_id

    timestamps()
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:live_stream_id, :creator_id, :text])
    |> validate_required([:live_stream_id, :creator_id, :text])
    |> validate_length(:text, min: 1, max: 500)
  end
end
