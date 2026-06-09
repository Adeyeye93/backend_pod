defmodule Pod.ListeningPresence do
  use Phoenix.Presence,
    otp_app: :pod,
    pubsub_server: Pod.PubSub
end
