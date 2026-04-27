defmodule Pod.BroadcasterSupervisor do
  @moduledoc """
  A DynamicSupervisor that spawns one broadcaster supervision tree
  per incoming RTMP connection.

  Each broadcaster gets their own supervised pair:

    BroadcasterSupervisor (DynamicSupervisor)
      └── BroadcasterSession (Supervisor, one_for_all)
            ├── Season     (GenServer — handles RTMP, auth, audio pipeline)
            └── Segmenter  (GenServer — writes segments, manages playlists)

  Using one_for_all for the inner pair means if Season crashes, Segmenter
  is also restarted — and vice versa. This prevents a zombie Segmenter
  writing segments for a Season that is gone, or a Season producing
  transcoded results with no Segmenter to receive them.

  Season and Segmenter share the live_stream_id. Season passes it to
  Segmenter when a segment is ready via Segmenter.write_segment/3.
  """

  use DynamicSupervisor
  require Logger

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Called by RTMPServer when a new broadcaster connects.
  Starts a supervised Session (Season + Segmenter pair) for the connection.
  """
  def start_broadcaster(socket) do
    spec = {Pod.BroadcasterSession, socket: socket}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        Logger.info("[BroadcasterSupervisor] Started broadcaster session — pid: #{inspect(pid)}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("[BroadcasterSupervisor] Failed to start session: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
