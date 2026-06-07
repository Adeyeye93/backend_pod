defmodule PodWeb.UploadController do
  use PodWeb, :controller

  alias Pod.Accounts.Guardian

  @allowed_types ~w(image/jpeg image/png image/webp)
  @presign_expires_seconds 300

  # ---------------------------------------------------------------------------
  # POST /api/uploads/thumbnail_presign
  #
  # Returns a presigned S3 PUT URL so the client can upload a thumbnail image
  # directly to S3 without routing the file through this server.
  #
  # Request params:
  #   content_type  — MIME type of the image (default: "image/jpeg")
  #
  # Response:
  #   upload_url    — presigned PUT URL, valid for 5 minutes
  #   thumbnail_url — the permanent public URL to store on the stream record
  #   expires_in    — seconds until upload_url expires
  #
  # Client steps:
  #   1. PUT <file bytes> to upload_url with Content-Type header matching content_type
  #   2. Pass thumbnail_url in POST /api/streams/create or PUT /api/creators/me
  # ---------------------------------------------------------------------------

  def thumbnail_presign(conn, params) do
    content_type = Map.get(params, "content_type", "image/jpeg")

    if content_type not in @allowed_types do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "content_type must be one of: #{Enum.join(@allowed_types, ", ")}"})
    else
      storage = Application.get_env(:pod, :storage, [])

      case Keyword.get(storage, :adapter) do
        :s3 ->
          generate_presigned_url(conn, content_type, storage)

        _ ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "File uploads require S3 storage. Enable it with USE_S3=true."})
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp generate_presigned_url(conn, content_type, storage) do
    bucket   = Keyword.fetch!(storage, :bucket)
    base_url = Keyword.get(storage, :base_url, "")
    user_id  = Guardian.Plug.current_resource(conn).id
    ext      = ext_for(content_type)
    key      = "thumbnails/#{user_id}/#{UUID.uuid4()}#{ext}"

    config = ExAws.Config.new(:s3)

    case ExAws.S3.presigned_url(config, :put, bucket, key,
           expires_in: @presign_expires_seconds,
           headers: [{"content-type", content_type}]
         ) do
      {:ok, upload_url} ->
        conn
        |> put_status(:ok)
        |> json(%{
          upload_url:    upload_url,
          thumbnail_url: "#{base_url}/#{key}",
          expires_in:    @presign_expires_seconds
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Could not generate upload URL: #{inspect(reason)}"})
    end
  end

  defp ext_for("image/jpeg"), do: ".jpg"
  defp ext_for("image/png"),  do: ".png"
  defp ext_for("image/webp"), do: ".webp"
end
