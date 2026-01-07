defmodule Pod.InterestsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Pod.Interests` context.
  """

  @doc """
  Generate a interest.
  """
  def interest_fixture(attrs \\ %{}) do
    {:ok, interest} =
      attrs
      |> Enum.into(%{
        color: "some color",
        description: "some description",
        icon: "some icon",
        name: "some name"
      })
      |> Pod.Interests.create_interest()

    interest
  end
end
