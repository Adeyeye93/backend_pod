defmodule Pod.BroadcasterSupervisor.Worker.StreamReminderWorker do
  use Oban.Worker,
  queue: :streams,
  max_attempts: 3,
  unique: [period: 60, fields: [:args]]

  alias Pod.Stream
  alias Pod.Accounts
  require Logger

  @messages %{
    "10_min"     => {"Stream starting soon", "Your stream starts in 10 minutes. Get ready!"},
    "5_min"      => {"5 minutes to go",      "Your stream starts in 5 minutes!"},
    "2_min"      => {"2 minutes to go",      "2 minutes until you go live. Final checks!"},
    "5_sec"      => {"Going live!",           "You are about to go live!"},
    "90_percent" => {"Starting soon",         "90% of your countdown has passed!"},
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stream_id" => stream_id, "threshold" => threshold}}) do
    with %{} = stream <- Stream.get_stream(stream_id),
         :scheduled   <- stream.status,
         {title, body} <- Map.get(@messages, threshold),
         %{} = user   <- Accounts.get_user_by_creator(stream.creator_id),
         token when not is_nil(token) <- user.push_token do
      send_push(token, title, body, %{stream_id: stream_id, threshold: threshold})
    end

    :ok
  end

  defp send_push(token, title, body, data) do
    case Req.post("https://exp.host/--/api/v2/push/send",
      json: %{to: token, title: title, body: body, data: data, sound: "default"}
    ) do
      {:ok, %{status: 200}} ->
        :ok
      {:ok, resp} ->
        Logger.warning("[StreamReminderWorker] Unexpected response: #{inspect(resp)}")
        :ok
      {:error, reason} ->
        Logger.error("[StreamReminderWorker] Push failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
