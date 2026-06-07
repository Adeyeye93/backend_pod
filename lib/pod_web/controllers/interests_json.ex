defmodule PodWeb.InterestsJSON do
  def index(%{interests: interests}) do
    %{data: Enum.map(interests, &interest/1)}
  end

  def interest(interest) do
    %{
      id: interest.id,
      name: interest.name,
      description: interest.description,
      last_update: interest.updated_at
    }
  end
end
