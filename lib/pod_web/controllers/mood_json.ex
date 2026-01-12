defmodule PodWeb.MoodJSON do
  def moodIndex(%{moods: moods}) do
    %{data: Enum.map(moods, &mood/1)}
  end

  def mood(mood) do
    %{
      id: mood.id,
      name: mood.name,
      description: mood.description,
    }
  end
end
