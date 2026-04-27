defmodule Pod.BroadcasterSession do
  @moduledoc """
  Supervises the Season and Segmenter pair for one broadcaster.

  Strategy is one_for_all — if either child crashes, both are restarted.
  This keeps Season and Segmenter always in sync with each other.

  Season is started first and holds the socket. Segmenter is started
  second and receives the Season pid so they can communicate.
  """

  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    socket = opts[:socket]

    # We need Season and Segmenter to know about each other.
    # The cleanest approach: start both with a shared Registry key
    # based on a generated session_id, so they can look each other up
    # without needing to pass PIDs directly at start time.
    session_id = generate_session_id()

    children = [
      %{
        id: :season,
        start: {
          Pod.BroadcasterSupervisor.Ingest.Season,
          :start_link,
          [%{socket: socket, session_id: session_id}]
        },
        restart: :temporary
      },
      %{
        id: :segmenter,
        start: {
          Pod.BroadcasterSupervisor.Ingest.Segmenter,
          :start_link,
          [%{session_id: session_id}]
        },
        restart: :temporary
      }
    ]

    # one_for_all — Season and Segmenter live and die together
    Supervisor.init(children, strategy: :one_for_all)
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
