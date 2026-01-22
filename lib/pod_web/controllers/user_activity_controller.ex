defmodule PodWeb.UserActivityController do
  use PodWeb, :controller
  alias Pod.Accounts
  alias Pod.Repo

 def set_am_a_creator(conn, %{"user_id" => user_id}) do
  user = Accounts.get_user!(user_id) |> Repo.preload(:creator)

  multi =
    Ecto.Multi.new()
    |> Ecto.Multi.update(
      :user,
      Ecto.Changeset.change(user, am_a_creator: true)
    )
    |> maybe_create_creator(user)

  case Repo.transaction(multi) do
    {:ok, _result} ->
      conn
      |> put_status(:ok)
      |> json(%{message: "User is now a creator"})

    {:error, _step, reason, _changes} ->
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "Failed to promote user", details: reason})
  end
end


defp maybe_create_creator(multi, %{creator: nil} = user) do
  Ecto.Multi.insert(
    multi,
    :creator,
    Ecto.build_assoc(user, :creator)
  )
end

defp maybe_create_creator(multi, %{creator: _creator}) do
  multi
end


end
