defmodule Pod.Follows do
  import Ecto.Query
  alias Pod.Repo
  alias Pod.Follows.Follow
  alias Pod.Stream.Creator
  alias Pod.Stream.LiveStream
  alias Pod.Creators

  # ---------------------------------------------------------------------------
  # Follow / unfollow
  # ---------------------------------------------------------------------------

  def follow_creator(user_id, creator_id) do
    case Repo.get_by(Follow, follower_id: user_id, creator_id: creator_id) do
      %Follow{} ->
        {:error, :already_following}

      nil ->
        result =
          %Follow{}
          |> Follow.changeset(%{follower_id: user_id, creator_id: creator_id})
          |> Repo.insert()

        case result do
          {:ok, _} = ok ->
            Creators.increment_followers_by_id(creator_id)
            ok

          error ->
            error
        end
    end
  end

  def unfollow_creator(user_id, creator_id) do
    case Repo.get_by(Follow, follower_id: user_id, creator_id: creator_id) do
      nil ->
        {:error, :not_following}

      %Follow{} = follow ->
        case Repo.delete(follow) do
          {:ok, _} = ok ->
            Creators.decrement_followers_by_id(creator_id)
            ok

          error ->
            error
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  def following?(user_id, creator_id) do
    Follow
    |> where([f], f.follower_id == ^user_id and f.creator_id == ^creator_id)
    |> Repo.exists?()
  end

  @doc "Returns Creator structs the user follows, with is_live derived."
  def list_followed_creators(user_id) do
    Follow
    |> where([f], f.follower_id == ^user_id)
    |> join(:inner, [f], c in assoc(f, :creator))
    |> preload(:creator)
    |> Repo.all()
    |> Enum.map(& &1.creator)
  end

  @doc "Returns {creators, live_creator_ids_mapset} — avoids N+1 for is_live."
  def list_followed_with_live(user_id) do
    creators = list_followed_creators(user_id)

    live_ids =
      if creators == [] do
        MapSet.new()
      else
        ids = Enum.map(creators, & &1.id)

        LiveStream
        |> where([s], s.status == "live" and s.creator_id in ^ids)
        |> select([s], s.creator_id)
        |> Repo.all()
        |> MapSet.new()
      end

    {creators, live_ids}
  end

  @doc "Returns creator IDs the user follows — used for feed filtering."
  def list_followed_creator_ids(user_id) do
    Follow
    |> where([f], f.follower_id == ^user_id)
    |> select([f], f.creator_id)
    |> Repo.all()
  end

  @doc "Returns user IDs who follow a given creator."
  def list_follower_ids(creator_id) do
    Follow
    |> where([f], f.creator_id == ^creator_id)
    |> select([f], f.follower_id)
    |> Repo.all()
  end

  def follower_count(creator_id) do
    Follow
    |> where([f], f.creator_id == ^creator_id)
    |> Repo.aggregate(:count)
  end
end
