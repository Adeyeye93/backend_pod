defmodule PodWeb.CreatorController do
  use PodWeb, :controller

  alias Pod.Creators
  alias Pod.Accounts.Guardian

  action_fallback PodWeb.FallbackController

  # ---------------------------------------------------------------------------
  # Create a creator profile for the authenticated user
  # POST /api/creators
  # ---------------------------------------------------------------------------

  def create(conn, params = %{"user_id" => user_id}) do
    if Creators.creator_exists_for_user?(user_id) do
      conn
      |> put_status(:ok)
      |> json(%{info: "Creator profile already exists for this account"})
    else
      case Creators.create_creator(Map.put(params, "user_id", user_id)) do
        {:ok, creator} ->
          conn
          |> put_status(:created)
          |> json(%{
            message: "Creator profile created",
            creator: format_creator(creator)
          })

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Get the authenticated user's creator profile
  # GET /api/creators/me
  # ---------------------------------------------------------------------------

  def me(conn, _params) do
    user_id = get_user_id(conn)

    case Creators.get_creator_by_user(user_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No creator profile found. Create one first."})

      creator ->
        conn
        |> put_status(:ok)
        |> json(%{creator: format_creator(creator)})
    end
  end

  # ---------------------------------------------------------------------------
  # Get a public creator profile by ID
  # GET /api/creators/:id
  # ---------------------------------------------------------------------------

  def show(conn, %{"id" => id}) do
    case Creators.get_creator_with_streams(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Creator not found"})

      creator ->
        conn
        |> put_status(:ok)
        |> json(%{creator: format_creator_public(creator)})
    end
  end

  # ---------------------------------------------------------------------------
  # Update the authenticated creator's profile
  # PUT /api/creators/me
  # ---------------------------------------------------------------------------

  def update(conn, params) do
    user_id = get_user_id(conn)

    with creator when not is_nil(creator) <- Creators.get_creator_by_user(user_id),
         {:ok, updated} <- Creators.update_creator(creator, params) do
      conn
      |> put_status(:ok)
      |> json(%{
        message: "Profile updated",
        creator: format_creator(updated)
      })
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Creator profile not found"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_user_id(conn) do
    Guardian.Plug.current_resource(conn).id
  end

  # Full profile — returned to the creator themselves
  defp format_creator(creator) do
    %{
      id: creator.id,
      channel_id: creator.channel_id,
      name: creator.name,
      avatar: creator.avatar,
      bio: creator.bio,
      follower_count: creator.follower_count,
      is_active: creator.is_active
    }
  end

  # Public profile — includes stream history, excludes internal fields
  defp format_creator_public(creator) do
    streams =
      case creator.live_streams do
        %Ecto.Association.NotLoaded{} ->
          []

        streams ->
          Enum.map(
            streams,
            &%{
              id: &1.id,
              title: &1.title,
              status: &1.status,
              scheduled_start_time: &1.scheduled_start_time
            }
          )
      end

    %{
      id: creator.id,
      channel_id: creator.channel_id,
      name: creator.name,
      avatar: creator.avatar,
      bio: creator.bio,
      follower_count: creator.follower_count,
      streams: streams
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
