defmodule PodWeb.UserController do
  use PodWeb, :controller

  alias Pod.Playlists
  alias Pod.Follows
  alias Pod.Accounts
  alias Pod.Playlist.UserPlaylist
  alias Pod.Accounts.Guardian

  action_fallback PodWeb.FallbackController

  @allowed_image_types ~w(image/jpeg image/png image/webp)

  # ---------------------------------------------------------------------------
  # GET /api/users/me
  # ---------------------------------------------------------------------------

  def show_me(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    conn
    |> put_status(:ok)
    |> json(%{
      user: %{
        id:         user.id,
        email:      user.email,
        username:   user.username,
        bio:        user.bio,
        avatar_url: user.avatar_url
      }
    })
  end

  # ---------------------------------------------------------------------------
  # PUT /api/users/me
  # Body: { username, bio }   — both optional
  # ---------------------------------------------------------------------------

  def update_me(conn, params) do
    user  = Guardian.Plug.current_resource(conn)
    attrs = Map.take(params, ["username", "bio"])

    case Accounts.update_profile(user, attrs) do
      {:ok, updated} ->
        conn
        |> put_status(:ok)
        |> json(%{
          user: %{
            id:         updated.id,
            email:      updated.email,
            username:   updated.username,
            bio:        updated.bio,
            avatar_url: updated.avatar_url
          }
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/users/me/avatar
  # Multipart form-data: avatar (file field)
  # ---------------------------------------------------------------------------

  def upload_avatar(conn, %{"avatar" => %Plug.Upload{} = upload}) do
    storage = Application.get_env(:pod, :storage, [])

    case Keyword.get(storage, :adapter) do
      :s3 ->
        do_s3_avatar_upload(conn, upload, storage)

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Avatar upload requires S3 storage"})
    end
  end

  def upload_avatar(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing avatar file field"})
  end

  # GET /api/users/me/following
  def following(conn, _params) do
    user_id = get_user_id(conn)
    {creators, live_ids} = Follows.list_followed_with_live(user_id)

    conn
    |> put_status(:ok)
    |> json(%{creators: Enum.map(creators, &format_creator(&1, live_ids))})
  end

  # GET /api/users/me/:playlist
  def playlist(conn, %{"playlist" => type}) do
    if Playlists.valid_type?(type) do
      user_id    = get_user_id(conn)
      recordings = Playlists.list_playlist(user_id, type)

      conn
      |> put_status(:ok)
      |> json(%{recordings: Enum.map(recordings, &format_recording/1)})
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Invalid playlist. Must be one of: #{Enum.join(UserPlaylist.valid_types(), ", ")}"})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_user_id(conn), do: Guardian.Plug.current_resource(conn).id

  defp do_s3_avatar_upload(conn, upload, storage) do
    user = Guardian.Plug.current_resource(conn)

    with true          <- upload.content_type in @allowed_image_types || {:error, :invalid_type},
         {:ok, binary} <- File.read(upload.path) do
      bucket   = Keyword.fetch!(storage, :bucket)
      base_url = Keyword.get(storage, :base_url, "")
      ext      = ext_for(upload.content_type)
      key      = "avatars/users/#{user.id}/#{UUID.uuid4()}#{ext}"

      case ExAws.S3.put_object(bucket, key, binary, content_type: upload.content_type)
           |> ExAws.request() do
        {:ok, _} ->
          avatar_url = "#{base_url}/#{key}"

          case Accounts.update_profile(user, %{avatar_url: avatar_url}) do
            {:ok, _updated} ->
              conn |> put_status(:ok) |> json(%{avatar_url: avatar_url})

            {:error, changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(changeset)})
          end

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "Upload failed: #{inspect(reason)}"})
      end
    else
      {:error, :invalid_type} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "File must be jpeg, png, or webp"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Could not read file: #{inspect(reason)}"})
    end
  end

  defp ext_for("image/jpeg"), do: ".jpg"
  defp ext_for("image/png"),  do: ".png"
  defp ext_for("image/webp"), do: ".webp"
  defp ext_for(_),            do: ".jpg"

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  defp format_recording(stream) do
    storage  = Application.get_env(:pod, :storage, [])
    base_url = Keyword.get(storage, :base_url, "")

    master_url =
      case Keyword.get(storage, :adapter) do
        :s3    -> "#{base_url}/broadcasters/#{stream.id}/master.m3u8"
        _local -> "#{base_url}/#{stream.id}/master.m3u8"
      end

    creator =
      case stream.creator do
        %Ecto.Association.NotLoaded{} -> nil
        c -> c
      end

    %{
      id:                stream.id,
      title:             stream.title,
      description:       stream.description,
      category:          stream.category,
      tags:              stream.tags,
      thumbnail:         stream.thumbnail,
      language:          stream.language,
      audio_quality:     stream.audio_quality,
      duration_seconds:  stream.duration_seconds,
      segment_count:     stream.segment_count,
      actual_start_time: stream.actual_start_time,
      end_time:          stream.end_time,
      creator_id:        stream.creator_id,
      creator_name:      creator && creator.name,
      creator_avatar:    creator && creator.avatar,
      peak_viewers:      stream.peak_viewers,
      master_url:        master_url
    }
  end

  defp format_creator(creator, live_ids) do
    %{
      id:             creator.id,
      name:           creator.name,
      thumbnail_url:  creator.avatar,
      follower_count: creator.follower_count,
      is_live:        MapSet.member?(live_ids, creator.id)
    }
  end
end
