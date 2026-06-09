defmodule PodWeb.CreatorController do
  use PodWeb, :controller

  alias Pod.Creators
  alias Pod.Follows
  alias Pod.Accounts.Guardian

  action_fallback PodWeb.FallbackController

  @allowed_image_types ~w(image/jpeg image/png image/webp)

  # ---------------------------------------------------------------------------
  # GET /api/creator/profile
  # ---------------------------------------------------------------------------

  def profile(conn, _params) do
    user_id = get_user_id(conn)

    case Creators.get_creator_by_user(user_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Creator profile not found"})

      creator ->
        recording_count = Pod.Stream.count_creator_recordings(creator.id)
        conn |> put_status(:ok) |> json(format_profile(creator, recording_count))
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /api/creator/profile
  # Body: { channel_name, bio }
  # ---------------------------------------------------------------------------

  def update_profile(conn, params) do
    user_id = get_user_id(conn)
    attrs   = %{"name" => params["channel_name"], "bio" => params["bio"]}
              |> Enum.reject(fn {_k, v} -> is_nil(v) end)
              |> Map.new()

    with creator when not is_nil(creator) <- Creators.get_creator_by_user(user_id),
         {:ok, updated} <- Creators.update_creator(creator, attrs) do
      recording_count = Pod.Stream.count_creator_recordings(updated.id)
      conn |> put_status(:ok) |> json(format_profile(updated, recording_count))
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Creator profile not found"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/creator/avatar
  # Multipart form-data: avatar (file field)
  # Uploads to S3, updates creator.avatar, returns { avatar_url }
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
  # Look up a creator by invite_key — used by host before sending an invite
  # GET /api/creators/lookup?invite_key=abc123
  # ---------------------------------------------------------------------------

  def lookup(conn, %{"invite_key" => invite_key}) do
    case Creators.get_creator_by_invite_key(invite_key) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "No creator found for that invite key"})

      creator ->
        conn
        |> put_status(:ok)
        |> json(%{
          creator: %{
            id:           creator.id,
            channel_name: creator.name,
            avatar_url:   creator.avatar
          }
        })
    end
  end

  def lookup(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "invite_key is required"})
  end

  # ---------------------------------------------------------------------------
  # Get a creator profile by ID
  # GET /api/creators/:id
  # ---------------------------------------------------------------------------

  def show(conn, %{"id" => id}) do
    case Creators.get_creator(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Creator not found"})

      creator ->
        user            = Guardian.Plug.current_resource(conn)
        recording_count = Pod.Stream.count_creator_recordings(id)
        is_following    = if user, do: Follows.following?(user.id, creator.id), else: false

        conn
        |> put_status(:ok)
        |> json(%{
          creator: %{
            id:              creator.id,
            channel_name:    creator.name,
            bio:             creator.bio,
            avatar_url:      creator.avatar,
            follower_count:  creator.follower_count,
            recording_count: recording_count,
            is_following:    is_following
          }
        })
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
  # List public recordings for a creator
  # GET /api/creators/:id/recordings
  # ---------------------------------------------------------------------------

  def creator_recordings(conn, %{"id" => creator_id}) do
    case Creators.get_creator(creator_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Creator not found"})

      _creator ->
        recordings = Pod.Stream.list_creator_recordings(creator_id)

        conn
        |> put_status(:ok)
        |> json(%{recordings: Enum.map(recordings, &format_recording_summary/1)})
    end
  end

  # ---------------------------------------------------------------------------
  # Follow a creator
  # POST /api/creators/:creator_id/follow
  # ---------------------------------------------------------------------------

  def follow(conn, %{"creator_id" => creator_id}) do
    user_id = get_user_id(conn)

    case Follows.follow_creator(user_id, creator_id) do
      {:ok, _} ->
        conn |> put_status(:ok) |> json(%{message: "Following"})

      {:error, :already_following} ->
        conn |> put_status(:ok) |> json(%{message: "Already following"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  # ---------------------------------------------------------------------------
  # Unfollow a creator
  # DELETE /api/creators/:creator_id/follow
  # ---------------------------------------------------------------------------

  def unfollow(conn, %{"creator_id" => creator_id}) do
    user_id = get_user_id(conn)

    case Follows.unfollow_creator(user_id, creator_id) do
      {:ok, _} ->
        conn |> put_status(:ok) |> json(%{message: "Unfollowed"})

      {:error, :not_following} ->
        conn |> put_status(:ok) |> json(%{message: "Not following"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
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

  # ---------------------------------------------------------------------------
  # S3 avatar upload
  # ---------------------------------------------------------------------------

  defp do_s3_avatar_upload(conn, upload, storage) do
    user_id = get_user_id(conn)

    with creator when not is_nil(creator) <- Creators.get_creator_by_user(user_id),
         true <- upload.content_type in @allowed_image_types || {:error, :invalid_type},
         {:ok, binary} <- File.read(upload.path) do
      bucket   = Keyword.fetch!(storage, :bucket)
      base_url = Keyword.get(storage, :base_url, "")
      ext      = ext_for_content_type(upload.content_type)
      key      = "avatars/#{creator.id}/#{UUID.uuid4()}#{ext}"

      case ExAws.S3.put_object(bucket, key, binary, content_type: upload.content_type)
           |> ExAws.request() do
        {:ok, _} ->
          avatar_url = "#{base_url}/#{key}"

          case Creators.update_creator(creator, %{avatar: avatar_url}) do
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
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Creator profile not found"})

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

  defp format_recording_summary(stream) do
    storage  = Application.get_env(:pod, :storage, [])
    base_url = Keyword.get(storage, :base_url, "")

    master_url =
      case Keyword.get(storage, :adapter) do
        :s3    -> "#{base_url}/broadcasters/#{stream.id}/master.m3u8"
        _local -> "#{base_url}/#{stream.id}/master.m3u8"
      end

    %{
      id:               stream.id,
      title:            stream.title,
      thumbnail_url:    stream.thumbnail,
      master_url:       master_url,
      duration_seconds: stream.duration_seconds,
      published_at:     stream.end_time
    }
  end

  defp format_profile(creator, recording_count) do
    %{
      id:              creator.id,
      channel_name:    creator.name,
      bio:             creator.bio,
      avatar_url:      creator.avatar,
      follower_count:  creator.follower_count,
      recording_count: recording_count
    }
  end

  defp ext_for_content_type("image/jpeg"), do: ".jpg"
  defp ext_for_content_type("image/png"),  do: ".png"
  defp ext_for_content_type("image/webp"), do: ".webp"
  defp ext_for_content_type(_),            do: ".jpg"
end
