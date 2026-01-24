defmodule PodWeb.UserActivityController do
  use PodWeb, :controller
  alias Pod.Accounts

  def set_am_a_creator(conn, %{"user_id" => user_id}) do
    current_user = Accounts.get_user!(user_id)
    case Pod.UserActivity.promote_user_to_creator(current_user) do
      {:ok, _} ->
        json(conn, %{message: "User promoted to creator"})

      {:error, _step, reason, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end

  # defp maybe_create_creator(multi, %{creator: nil} = user) do
  #   Ecto.Multi.insert(
  #     multi,
  #     :creator,
  #     Ecto.build_assoc(user, :creator)
  #   )
  # end

  # defp maybe_create_creator(multi, %{creator: _creator}) do
  #   multi
  # end
end
