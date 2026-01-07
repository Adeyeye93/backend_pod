defmodule Pod.Interests do
  @moduledoc """
  The Interests context.
  """

  import Ecto.Query, warn: false
  alias Pod.Repo

  alias Pod.Interests.Interest
  alias Pod.Accounts.UserInterest
  alias Pod.Accounts.User

  @doc """
  Returns the list of interests.

  ## Examples

      iex> list_interests()
      [%Interest{}, ...]

  """
  def list_interests do
    Repo.all(Interest)
  end

  @doc """
  Gets a single interest.

  Raises `Ecto.NoResultsError` if the Interest does not exist.

  ## Examples

      iex> get_interest!(123)
      %Interest{}

      iex> get_interest!(456)
      ** (Ecto.NoResultsError)

  """
  def get_interest!(id), do: Repo.get!(Interest, id)

  @doc """
  Creates a interest.

  ## Examples

      iex> create_interest(%{field: value})
      {:ok, %Interest{}}

      iex> create_interest(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_interest(attrs) do
    %Interest{}
    |> Interest.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a interest.

  ## Examples

      iex> update_interest(interest, %{field: new_value})
      {:ok, %Interest{}}

      iex> update_interest(interest, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_interest(%Interest{} = interest, attrs) do
    interest
    |> Interest.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a interest.

  ## Examples

      iex> delete_interest(interest)
      {:ok, %Interest{}}

      iex> delete_interest(interest)
      {:error, %Ecto.Changeset{}}

  """
  def delete_interest(%Interest{} = interest) do
    Repo.delete(interest)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking interest changes.

  ## Examples

      iex> change_interest(interest)
      %Ecto.Changeset{data: %Interest{}}

  """
   def list_interests_by_type(type) do
    Interest
    |> where([i], i.category == ^type)
    |> Repo.all()
  end

  # Add interests to user
def update_user_interests(user_id, interest_ids) when is_list(interest_ids) do
  user_id = String.to_integer(user_id)
  now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  date_Time = DateTime.utc_now() |> DateTime.truncate(:second)

  Repo.transaction(fn ->
    # 1. Remove interests that are no longer selected
    from(ui in UserInterest,
      where: ui.user_id == ^user_id and ui.interest_id not in ^interest_ids
    )
    |> Repo.delete_all()

    # 2. Insert missing interests
    existing_ids =
      from(ui in UserInterest,
        where: ui.user_id == ^user_id,
        select: ui.interest_id
      )
      |> Repo.all()

    new_ids = interest_ids -- existing_ids

    entries =
      Enum.map(new_ids, fn interest_id ->
        %{
          user_id: user_id,
          interest_id: interest_id,
          inserted_at: date_Time,
          updated_at: date_Time
        }
      end)

    if entries != [] do
      Repo.insert_all(UserInterest, entries)
    end

    # 3. Update user metadata
    user = Repo.get!(User, user_id)

    user
    |> User.interest_changeset(%{
      has_interest: true,
      interests_selected_at: now
    })
    |> Repo.update!()

    %{added: length(new_ids), total: length(interest_ids)}
  end)
end






# Get user interests
  def get_user_interests(user_id) do
    UserInterest
    |> where([ui], ui.user_id == ^user_id)
    |> preload(:interest)
    |> Repo.all()
    |> Enum.map(& &1.interest)
  end

  # Remove user interest
  def remove_user_interest(user_id, interest_id) do
    UserInterest
    |> where([ui], ui.user_id == ^user_id and ui.interest_id == ^interest_id)
    |> Repo.delete_all()
  end

  # Clear all user interests
  def clear_user_interests(user_id) do
    UserInterest
    |> where([ui], ui.user_id == ^user_id)
    |> Repo.delete_all()
  end

  # Check if user has selected interests
  def user_has_interests?(user_id) do
    User
    |> where([u], u.id == ^user_id)
    |> select([u], u.has_interest)
    |> Repo.one() || false
  end

  def change_interest(%Interest{} = interest, attrs \\ %{}) do
    Interest.changeset(interest, attrs)
  end
end
