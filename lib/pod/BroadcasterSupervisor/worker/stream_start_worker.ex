defmodule Pod.BroadcasterSupervisor.Worker.StreamStartWorker do
  use Oban.Worker,
  queue: :streams,
  max_attempts: 5,
  unique: [period: 300, fields: [:args]]

  alias Pod.Stream
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stream_id" => stream_id}}) do
    with %{} = stream <- Stream.get_stream(stream_id),
         :scheduled   <- stream.status do
      {:ok, _} = Stream.start_stream(stream)

      # Broadcast to all listeners watching this stream
      PodWeb.Endpoint.broadcast("stream:#{stream_id}", "stream_state", %{
        status: "live",
        stream_id: stream_id
      })

      Logger.info("[StreamStartWorker] Stream #{stream_id} auto-started")
    end

    :ok
  end
end
