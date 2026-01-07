defmodule Pod.Accounts.Guardian do
    use Guardian, otp_app: :pod

  alias Pod.Accounts

  # Encode user data into JWT claims
  def subject_for_token(user, _claims) do
    {:ok, to_string(user.id)}
  end

  # Decode JWT claims back to user resource
  def resource_from_claims(claims) do
    case Accounts.get_user!(claims["sub"]) do
      %Accounts.User{} = user -> {:ok, user}
      nil -> {:error, :resource_not_found}
    end
  rescue
    _ -> {:error, :resource_not_found}
  end

  # Optional: Token verification hooks
  def verify_claims(claims) do
    {:ok, claims}
  end

  def generate_tokens(user) do
    with {:ok, access_token, _} <- encode_and_sign(user, %{}, token_type: "access"),
         {:ok, refresh_token, _} <- encode_and_sign(user, %{}, token_type: "refresh", ttl: {120, :days}) do
      {:ok, access_token, refresh_token}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
