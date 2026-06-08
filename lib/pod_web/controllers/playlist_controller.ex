defmodule PodWeb.PlaylistController do
  use PodWeb, :controller

  alias Pod.Playlists
  alias Pod.Stream
  alias Pod.Playlist.UserPlaylist
  alias Pod.Accounts.Guardian

  action_fallback PodWeb.FallbackController

  # POST /api/recordings/:recording_id/:playlist
  def add(conn, %{"recording_id" => recording_id, "playlist" => type}) do
    with true          <- Playlists.valid_type?(type) || {:error, :invalid_type},
         stream when not is_nil(stream) <- Stream.get_stream(recording_id),
         {:ok, _}      <- Playlists.add_to_playlist(get_user_id(conn), recording_id, type) do
      conn |> put_status(:ok) |> json(%{message: "added"})
    else
      {:error, :invalid_type} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid playlist. Must be one of: #{Enum.join(UserPlaylist.valid_types(), ", ")}"})

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Recording not found"})

      {:error, :already_exists} ->
        conn |> put_status(:conflict) |> json(%{error: "Already in playlist"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  # DELETE /api/recordings/:recording_id/:playlist
  def remove(conn, %{"recording_id" => recording_id, "playlist" => type}) do
    if Playlists.valid_type?(type) do
      case Playlists.remove_from_playlist(get_user_id(conn), recording_id, type) do
        {:ok, :removed}     -> conn |> put_status(:ok) |> json(%{message: "removed"})
        {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "Not in playlist"})
      end
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Invalid playlist. Must be one of: #{Enum.join(UserPlaylist.valid_types(), ", ")}"})
    end
  end

  defp get_user_id(conn), do: Guardian.Plug.current_resource(conn).id

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
