defmodule PodWeb.AuthErrorHandler do
  import Plug.Conn

  def auth_error(conn, {type, reason}, _opts) do
    {status, code, message} =
      case {type, reason} do
        {:unauthenticated, _} ->
          {401, "unauthenticated", "Authentication required"}

        {:invalid_token, _} ->
          {401, "invalid_token", "Invalid access token"}

        {:token_expired, _} ->
          {401, "token_expired", "Access token expired"}

        {:no_resource_found, _} ->
          {401, "no_resource", "User no longer exists"}

        {:unauthorized, _} ->
          {403, "forbidden", "You do not have access to this resource"}

        _ ->
          {401, "auth_error", "Authentication error"}
      end

    body =
      Jason.encode!(%{
        error: %{
          code: code,
          message: message
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end

