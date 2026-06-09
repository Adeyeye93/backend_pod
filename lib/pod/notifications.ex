defmodule Pod.Notifications do
  @moduledoc """
  Thin wrapper around the Expo Push API.

  All push notifications in the app go through here. Each typed function
  takes a User struct (must have push_token) and fires a non-blocking
  request to Expo's push service. Silently skips if push_token is nil.

  Expo docs: https://docs.expo.dev/push-notifications/sending-notifications/
  """

  require Logger

  @expo_url "https://exp.host/--/api/v2/push/send"

  # ---------------------------------------------------------------------------
  # Typed notification functions
  # ---------------------------------------------------------------------------

  def notify_invite_received(user, stream_title, host_name) do
    push(user,
      "You've been invited!",
      "#{host_name} invited you to join \"#{stream_title}\"",
      %{type: "invite_received", stream_title: stream_title}
    )
  end

  def notify_invite_accepted(user, guest_name) do
    push(user,
      "Invite accepted",
      "#{guest_name} accepted your invite and will join the stream",
      %{type: "invite_accepted"}
    )
  end

  def notify_invite_declined(user, guest_name) do
    push(user,
      "Invite declined",
      "#{guest_name} won't be joining your stream",
      %{type: "invite_declined"}
    )
  end

  def notify_stream_reminder(user, stream_id, threshold) do
    {title, body} = reminder_copy(threshold)
    push(user, title, body, %{type: "stream_reminder", stream_id: stream_id, threshold: threshold})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp push(%{push_token: nil}, _title, _body, _data), do: :ok
  defp push(%{push_token: token}, title, body, data) do
    send_push(token, title, body, data)
  end
  defp push(_, _, _, _), do: :ok

  defp send_push(token, title, body, data) do
    payload = %{to: token, title: title, body: body, data: data, sound: "default"}

    case Req.post(@expo_url, json: payload) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, resp} ->
        Logger.warning("[Notifications] Unexpected Expo response: #{inspect(resp.status)}")
        :ok

      {:error, reason} ->
        Logger.error("[Notifications] Push failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp reminder_copy("10_min"),     do: {"Stream starting soon", "Your stream starts in 10 minutes. Get ready!"}
  defp reminder_copy("5_min"),      do: {"5 minutes to go", "Your stream starts in 5 minutes!"}
  defp reminder_copy("2_min"),      do: {"2 minutes to go", "2 minutes until you go live. Final checks!"}
  defp reminder_copy("5_sec"),      do: {"Going live!", "You are about to go live!"}
  defp reminder_copy("90_percent"), do: {"Starting soon", "90% of your countdown has passed!"}
  defp reminder_copy(_),            do: {"Stream reminder", "Your stream is starting soon!"}
end
