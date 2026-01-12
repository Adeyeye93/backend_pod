defmodule Pod.Moods.Mood do
  use Ecto.Schema
  import Ecto.Changeset

  schema "moods" do
    field :name, :string
    field :description, :string
    field :icon, :string
    field :color, :string, default: "#000000"
    field :is_active, :boolean, default: true

    # Associations (if you want to link moods to podcasts later)
    # many_to_many :podcasts, YourApp.Podcasts.Podcast, join_through: "podcast_moods"

    timestamps()
  end

  @doc false
  def changeset(mood, attrs) do
    mood
    |> cast(attrs, [:name, :description, :icon, :color, :is_active])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
