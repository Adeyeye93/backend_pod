defmodule Pod.Workers.AudioPackagingWorker do
  @moduledoc """
  Oban worker that converts a saved HLS recording into a single downloadable MP3.

  Triggered 30 seconds after a live stream ends. By the time Segmenter.finalise
  runs, all segments are already in S3 (GenServer cast ordering guarantees this),
  so the delay is just a small buffer for S3 eventual consistency.

  Unique per stream_id within a 10-minute window, so duplicate enqueues from
  multiple end_stream callers are de-duplicated automatically.

  Requires FFmpeg on PATH and S3 storage configured.
  Skips gracefully (returns :ok) when either is absent.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 600, fields: [:args]]

  require Logger

  alias Pod.Stream.LiveStream
  alias Pod.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stream_id" => stream_id}}) do
    storage = Application.get_env(:pod, :storage, [])

    cond do
      Keyword.get(storage, :adapter) != :s3 ->
        Logger.info("[AudioPackaging] Skipping #{stream_id}: S3 not configured")
        :ok

      not ffmpeg_available?() ->
        Logger.warning("[AudioPackaging] Skipping #{stream_id}: ffmpeg not on PATH")
        :ok

      true ->
        package(stream_id, storage)
    end
  end

  # ---------------------------------------------------------------------------
  # Core logic
  # ---------------------------------------------------------------------------

  defp package(stream_id, storage) do
    stream = Repo.get(LiveStream, stream_id)

    cond do
      is_nil(stream) ->
        Logger.warning("[AudioPackaging] Stream #{stream_id} not found")
        :ok

      stream.status != "ended" or not stream.record_stream ->
        Logger.info("[AudioPackaging] Skipping #{stream_id}: not a saved recording")
        :ok

      not is_nil(stream.download_url) ->
        Logger.info("[AudioPackaging] Already done for #{stream_id}")
        :ok

      true ->
        run_ffmpeg_and_upload(stream, storage)
    end
  end

  defp run_ffmpeg_and_upload(stream, storage) do
    base_url = Keyword.get(storage, :base_url, "")
    m3u8_url = "#{base_url}/broadcasters/#{stream.id}/master.m3u8"

    tmp_dir     = Path.join(System.tmp_dir!(), "pod_audio_#{stream.id}_#{:rand.uniform(999_999)}")
    output_path = Path.join(tmp_dir, "output.mp3")

    File.mkdir_p!(tmp_dir)

    try do
      # Re-encode to MP3 so the output plays on every podcast player.
      # -q:a 2 ≈ 190 kbps VBR — high quality without massive file size.
      ffmpeg_args = [
        "-y",
        "-i", m3u8_url,
        "-vn",           # drop any video track
        "-c:a", "libmp3lame",
        "-q:a", "2",
        output_path
      ]

      case System.cmd("ffmpeg", ffmpeg_args, stderr_to_stdout: true, cd: tmp_dir) do
        {_out, 0} ->
          upload_and_save(stream, output_path, storage)

        {out, code} ->
          snippet = String.slice(out, 0, 600)
          Logger.error("[AudioPackaging] FFmpeg exited #{code} for #{stream.id}: #{snippet}")
          {:error, "ffmpeg exit #{code}"}
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp upload_and_save(stream, file_path, storage) do
    bucket   = Keyword.fetch!(storage, :bucket)
    base_url = Keyword.get(storage, :base_url, "")
    key      = "recordings/#{stream.id}/download.mp3"

    # Stream the file to S3 in chunks — avoids loading the whole MP3 into memory.
    result =
      file_path
      |> ExAws.S3.Upload.stream_file()
      |> ExAws.S3.upload(bucket, key, content_type: "audio/mpeg")
      |> ExAws.request()

    case result do
      {:ok, _} ->
        download_url = "#{base_url}/#{key}"

        stream
        |> LiveStream.packaging_changeset(%{download_url: download_url})
        |> Repo.update()
        |> case do
          {:ok, _} ->
            Logger.info("[AudioPackaging] Done #{stream.id} → #{download_url}")
            :ok

          {:error, reason} ->
            Logger.error("[AudioPackaging] DB update failed for #{stream.id}: #{inspect(reason)}")
            {:error, "db update failed"}
        end

      {:error, reason} ->
        Logger.error("[AudioPackaging] S3 upload failed for #{stream.id}: #{inspect(reason)}")
        {:error, "s3 upload failed"}
    end
  end

  defp ffmpeg_available?, do: not is_nil(System.find_executable("ffmpeg"))
end
