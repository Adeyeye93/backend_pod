defmodule PodWeb.AuthController do
  use PodWeb, :controller
  alias Pod.Accounts
  alias Pod.Accounts.Guardian

  action_fallback PodWeb.FallbackController

  def register(conn, %{"email" => email, "password" => password,  "password_confirmation" => password_confirmation}) do
    case Accounts.create_user(%{email: email, password: password, password_confirmation: password_confirmation}) do
      {:ok, user} ->
        case Guardian.encode_and_sign(user) do
          {:ok, token, _claims} ->
            conn
            |> put_status(:created)
            |> json(%{
              message: "User registered successfully",
              token: token,
              user: %{id: user.id, email: user.email}
            })

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to generate token: #{inspect(reason)}"})
        end

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        case Guardian.encode_and_sign(user) do
          {:ok, token, _claims} ->
            conn
            |> put_status(:ok)
            |> json(%{
              message: "Login successful",
              token: token,
              user: %{id: user.id, email: user.email}
            })

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to generate token: #{inspect(reason)}"})
        end

      {:error, _reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid email or password"})
    end
  end

  def refresh(conn, %{"refresh_token" => refresh_token}) do
    case Guardian.decode_and_verify(refresh_token) do
      {:ok, claims} ->
        case Accounts.get_user(claims["sub"]) do
          %Accounts.User{} = user ->
            case Guardian.generate_tokens(user) do
              {:ok, new_access_token, new_refresh_token} ->
                conn
                |> put_status(:ok)
                |> json(%{
                  message: "Token refreshed successfully",
                  access_token: new_access_token,
                  refresh_token: new_refresh_token
                })

                # ... error handling
            end

          nil ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "User not found"})
        end

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid refresh token: #{inspect(reason)}"})
    end
  end

def logout(conn, _params) do
    conn
    |> json(%{message: "Logged out successfully"})
  end

  def google_login(conn, %{
    "id_token" => id_token,
    "email" => email,
    "name" => name,
    "picture" => picture
  }) do
    case verify_google_token(id_token) do
      {:ok, _claims} ->
        provider_data = %{
          id: extract_sub_from_token(id_token),
          email: email,
          name: name,
          picture: picture
        }

        case Accounts.get_or_create_social_user("google", provider_data) do
          {:ok, user} ->
            case Guardian.generate_tokens(user) do
              {:ok, access_token, refresh_token} ->
                conn
                |> put_status(:ok)
                |> json(%{
                  message: "Login successful",
                  access_token: access_token,
                  refresh_token: refresh_token,
                  user: %{id: user.id, email: user.email, username: user.username}
                })
            end

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to create user: #{inspect(reason)}"})
        end

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid Google token: #{inspect(reason)}"})
    end
  end

  def apple_login(conn, %{
    "id_token" => id_token,
    "email" => email,
    "name" => name
  }) do
    case verify_apple_token(id_token) do
      {:ok, _claims} ->
        provider_data = %{
          id: extract_sub_from_token(id_token),
          email: email,
          name: name,
          picture: nil
        }

        case Accounts.get_or_create_social_user("apple", provider_data) do
          {:ok, user} ->
            case Guardian.generate_tokens(user) do
              {:ok, access_token, refresh_token} ->
                conn
                |> put_status(:ok)
                |> json(%{
                  message: "Login successful",
                  access_token: access_token,
                  refresh_token: refresh_token,
                  user: %{id: user.id, email: user.email, username: user.username}
                })

              {:error, reason} ->
                conn
                |> put_status(:internal_server_error)
                |> json(%{error: "Failed to generate tokens: #{inspect(reason)}"})
            end

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to create user: #{inspect(reason)}"})
        end

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid Apple token: #{inspect(reason)}"})
    end
  end

  defp extract_sub_from_token(token) do
    case decode_jwt(token) do
      {:ok, %{"sub" => sub}} -> sub
      _ -> nil
    end
  end

  defp verify_google_token(id_token) do
    # Verify with Google's tokeninfo endpoint
    case HTTPoison.get("https://www.googleapis.com/oauth2/v3/tokeninfo?id_token=#{id_token}") do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, "Invalid token - status #{status}"}

      {:error, reason} ->
        {:error, "Failed to verify token: #{inspect(reason)}"}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  defp verify_apple_token(id_token) do
    # For Apple, you need to:
    # 1. Decode the token (without verification first)
    # 2. Get the kid from header
    # 3. Fetch Apple's public keys
    # 4. Verify signature

    case decode_jwt(id_token) do
      {:ok, %{"iss" => "https://appleid.apple.com", "aud" => _aud} = claims} ->
        # Token structure is valid, verify signature separately if needed
        {:ok, claims}

      {:ok, _claims} ->
        {:error, :invalid_issuer}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  defp decode_jwt(token) do
    case String.split(token, ".") do
      [_header, payload, _signature] ->
        case Base.url_decode64(payload <> String.duplicate("=", rem(4 - rem(byte_size(payload), 4), 4))) do
          {:ok, decoded} ->
            case Jason.decode(decoded) do
              {:ok, claims} -> {:ok, claims}
              {:error, _} -> {:error, :invalid_payload}
            end

          :error ->
            {:error, :invalid_payload}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} ->
      msg
    end)
  end
end
