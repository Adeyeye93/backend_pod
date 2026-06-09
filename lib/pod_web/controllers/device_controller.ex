defmodule PodWeb.DeviceController do
  use PodWeb, :controller

  alias Pod.Accounts
  alias Pod.Accounts.Guardian

  action_fallback PodWeb.FallbackController

  # PUT /api/users/me/push_token
  # Body: { "push_token": "ExponentPushToken[xxxx]" }
  # Called by the mobile app on login and whenever the Expo token changes.
  def register(conn, %{"push_token" => token}) do
    user = Guardian.Plug.current_resource(conn)

    case Accounts.update_push_token(user, token) do
      {:ok, _} ->
        conn |> put_status(:ok) |> json(%{message: "Push token registered"})

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors})
    end
  end

  def register(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "push_token is required"})
  end
end
