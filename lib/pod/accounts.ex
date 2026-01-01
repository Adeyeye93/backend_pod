defmodule Pod.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Pod.Repo

  alias Pod.Accounts.User
  import Ecto.Query
  alias Pod.Accounts.SocialAccount

  @doc """
  Returns the list of users.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  def list_users do
    Repo.all(User)
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Creates a user.

  ## Examples

      iex> create_user(%{field: value})
      {:ok, %User{}}

      iex> create_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user.

  ## Examples

      iex> update_user(user, %{field: new_value})
      {:ok, %User{}}

      iex> update_user(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.registration_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a user.

  ## Examples

      iex> delete_user(user)
      {:ok, %User{}}

      iex> delete_user(user)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  def get_user(id) do
    Repo.get(User, id)
  end

  def authenticate_user(email, password) do
    user = Repo.get_by(User, email: String.downcase(email))

    case user do
      nil ->
        {:error, :invalid_credentials}

      user ->
        if user.is_active && Argon2.verify_pass(password, user.password_hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  def get_or_create_social_user(provider, provider_data) do
    case get_social_account(provider, provider_data.id) do
      # User already exists via this social provider
      %SocialAccount{user: user} ->
        {:ok, user}

      # First time social login - create new user
      nil ->
        with {:ok, user} <- create_social_user(provider_data),
             {:ok, _social_account} <- create_social_account(user, provider, provider_data) do
          {:ok, user}
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp get_social_account(provider, provider_id) do
    SocialAccount
    |> where([sa], sa.provider == ^provider and sa.provider_id == ^provider_id)
    |> preload(:user)
    |> Repo.one()
  end

  defp create_social_user(provider_data) do
    %User{}
    |> Ecto.Changeset.cast(
      %{
        email: provider_data.email,
        username: provider_data.name || String.split(provider_data.email, "@") |> List.first(),
        avatar_url: provider_data.picture
      },
      [:email, :username, :avatar_url]
    )
    |> Ecto.Changeset.validate_required([:email])
    |> Ecto.Changeset.unique_constraint(:email)
    |> Repo.insert()
  end

  defp create_social_account(user, provider, provider_data) do
    %SocialAccount{}
    |> SocialAccount.changeset(%{
      provider: provider,
      provider_id: provider_data.id,
      provider_email: provider_data.email,
      provider_name: provider_data.name,
      user_id: user.id
    })
    |> Repo.insert()
  end
end
