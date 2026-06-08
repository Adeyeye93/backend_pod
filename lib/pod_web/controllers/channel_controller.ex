defmodule PodWeb.ChannelController do
  use PodWeb, :controller

  alias Pod.Creators
  alias Pod.Follows
  alias Pod.Accounts.Guardian

  action_fallback PodWeb.FallbackController

  # POST /api/channels/:channel_id/follow
  def follow(conn, %{"channel_id" => channel_id}) do
    user_id = get_user_id(conn)

    case Creators.get_creator_by_channel(channel_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Channel not found"})

      creator ->
        case Follows.follow_creator(user_id, creator.id) do
          {:ok, _} ->
            conn |> put_status(:ok) |> json(%{message: "followed"})

          {:error, :already_following} ->
            conn |> put_status(:conflict) |> json(%{error: "Already following"})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_errors(changeset)})
        end
    end
  end

  # DELETE /api/channels/:channel_id/follow
  def unfollow(conn, %{"channel_id" => channel_id}) do
    user_id = get_user_id(conn)

    case Creators.get_creator_by_channel(channel_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Channel not found"})

      creator ->
        case Follows.unfollow_creator(user_id, creator.id) do
          {:ok, _} ->
            conn |> put_status(:ok) |> json(%{message: "unfollowed"})

          {:error, :not_following} ->
            conn |> put_status(:not_found) |> json(%{error: "Not following this channel"})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: inspect(reason)})
        end
    end
  end

  defp get_user_id(conn), do: Guardian.Plug.current_resource(conn).id

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
