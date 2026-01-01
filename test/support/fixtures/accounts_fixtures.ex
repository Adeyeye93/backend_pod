defmodule Pod.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Pod.Accounts` context.
  """

  @doc """
  Generate a user.
  """
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        avatar_url: "some avatar_url",
        bio: "some bio",
        created_at: ~N[2025-12-29 10:02:00],
        email: "some email",
        password: "some password",
        updated_at: ~N[2025-12-29 10:02:00],
        username: "some username"
      })
      |> Pod.Accounts.create_user()

    user
  end
end
