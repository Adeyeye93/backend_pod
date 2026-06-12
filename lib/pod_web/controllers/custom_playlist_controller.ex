defmodule PodWeb.CustomPlaylistController do
  use PodWeb, :controller

  alias Pod.CustomPlaylists
  alias Pod.ListeningHistory
  alias Pod.Accounts.Guardian

  action_fallback PodWeb.FallbackController

  # ---------------------------------------------------------------------------
  # GET /api/playlists
  # Returns all user playlists with recordings embedded.
  # ---------------------------------------------------------------------------

  def index(conn, _params) do
    user_id   = get_user_id(conn)
    playlists = CustomPlaylists.list_playlists(user_id)

    # Batch-load progress for every recording across all playlists
    all_stream_ids =
      playlists
      |> Enum.flat_map(fn p -> Enum.map(p.recordings, & &1.live_stream_id) end)
      |> Enum.uniq()

    progress_map = ListeningHistory.get_progress_map(user_id, all_stream_ids)

    conn
    |> put_status(:ok)
    |> json(%{playlists: Enum.map(playlists, &format_playlist(&1, progress_map))})
  end

  # ---------------------------------------------------------------------------
  # POST /api/playlists
  # Body: { "name": "Weekend Picks" }
  # ---------------------------------------------------------------------------

  def create(conn, %{"name" => name}) when is_binary(name) and name != "" do
    user_id = get_user_id(conn)

    case CustomPlaylists.create_playlist(user_id, name) do
      {:ok, playlist} ->
        conn
        |> put_status(:created)
        |> json(%{playlist: format_playlist(playlist, %{})})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "name is required"})
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/playlists/:id
  # ---------------------------------------------------------------------------

  def delete(conn, %{"id" => id}) do
    user_id = get_user_id(conn)

    case CustomPlaylists.delete_playlist(id, user_id) do
      {:ok, _}         -> conn |> put_status(:ok) |> json(%{ok: true})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "Playlist not found"})
      {:error, _}      -> conn |> put_status(:internal_server_error) |> json(%{error: "Could not delete playlist"})
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/playlists/:id/recordings
  # Body: { "recording_id": "uuid" }
  # ---------------------------------------------------------------------------

  def add_recording(conn, %{"id" => playlist_id, "recording_id" => recording_id}) do
    user_id = get_user_id(conn)

    case CustomPlaylists.add_recording(playlist_id, user_id, recording_id) do
      :ok ->
        conn |> put_status(:ok) |> json(%{ok: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Playlist not found"})

      {:error, :recording_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Recording not found"})

      {:error, :already_exists} ->
        conn |> put_status(:conflict) |> json(%{error: "Recording already in playlist"})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Could not add recording"})
    end
  end

  def add_recording(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "recording_id is required"})
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/playlists/:id/recordings/:recording_id
  # ---------------------------------------------------------------------------

  def remove_recording(conn, %{"id" => playlist_id, "recording_id" => recording_id}) do
    user_id = get_user_id(conn)

    case CustomPlaylists.remove_recording(playlist_id, user_id, recording_id) do
      {:ok, _} ->
        conn |> put_status(:ok) |> json(%{ok: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Not found"})

      {:error, _} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "Could not remove recording"})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_user_id(conn), do: Guardian.Plug.current_resource(conn).id

  defp format_playlist(playlist, progress_map) do
    %{
      id:         playlist.id,
      name:       playlist.name,
      created_at: playlist.inserted_at,
      recordings: Enum.map(playlist.recordings, &format_recording(&1, progress_map))
    }
  end

  defp format_recording(playlist_recording, progress_map) do
    s       = playlist_recording.live_stream
    creator = case s.creator do
      %Ecto.Association.NotLoaded{} -> nil
      c -> c
    end

    %{
      id:               s.id,
      title:            s.title,
      creator_name:     creator && creator.name,
      thumbnail_url:    s.thumbnail,
      master_url:       s.download_url,
      download_url:     s.download_url,
      duration_seconds: s.duration_seconds,
      progress_seconds: Map.get(progress_map, s.id, 0)
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
