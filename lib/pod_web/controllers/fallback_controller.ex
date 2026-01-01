defmodule PodWeb.FallbackController do
   use PodWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found"})
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Unauthorized"})
  end

  def call(conn, {:error, :invalid_credentials}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Invalid credentials"})
  end

  def call(conn, {:error, changeset}) when is_map(changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: format_errors(changeset)})
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: to_string(reason)})
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} ->
      msg
    end)
  end
end
