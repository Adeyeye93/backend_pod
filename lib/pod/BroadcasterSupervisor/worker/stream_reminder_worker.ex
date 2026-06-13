defmodule Pod.BroadcasterSupervisor.Worker.StreamReminderWorker do
  use Oban.Worker,
    queue: :streams,
    max_attempts: 3,
    unique: [period: 60, fields: [:args, :worker]]

  alias Pod.Stream
  alias Pod.Accounts
  alias Pod.Notifications

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stream_id" => stream_id, "threshold" => threshold}}) do
    with %{} = stream <- Stream.get_stream(stream_id),
         :scheduled   <- stream.status,
         %{} = user   <- Accounts.get_user_by_creator(stream.creator_id) do
      Notifications.notify_stream_reminder(user, stream_id, threshold)
    end

    :ok
  end
end
