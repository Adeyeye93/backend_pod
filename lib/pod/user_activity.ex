defmodule Pod.UserActivity do
  alias Pod.Accounts.User
  alias Pod.Repo
  alias Pod.Stream.Creator

  def promote_user_to_creator(%User{} = user) do
  user = Repo.preload(user, :creator)

  Ecto.Multi.new()
  |> Ecto.Multi.run(:creator, fn _repo, _changes ->
    case user.creator do
      nil ->
        user
        |> Ecto.build_assoc(:creator)
        |> Creator.changeset(%{})
        |> Repo.insert()

      creator ->
        {:ok, creator}
    end
  end)
  |> Ecto.Multi.update(
    :user,
    Ecto.Changeset.change(user, am_a_creator: true)
  )
  |> Repo.transaction()
end

end
