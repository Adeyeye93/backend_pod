defmodule PodWeb.FeedChannel do
  use PodWeb, :channel

  alias Pod.Stream

  @impl true
  def join("feed:all", _payload, socket) do
    # Push current live streams immediately on join so the
    # client doesn't have to make a separate HTTP request
    streams = Stream.list_live_streams()

    {:ok, %{streams: Enum.map(streams, &PodWeb.StreamController.format_stream_public/1)}, socket}
  end

  def join("feed:" <> _category, _payload, socket) do
    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Broadcast helpers — called from Season and Segmenter
  # ---------------------------------------------------------------------------

  @doc """
  Called when a broadcaster connects and the stream goes live.
  Pushes the stream to all listeners on the feed channel.
  """
  def stream_started(stream) do
    PodWeb.Endpoint.broadcast("feed:all", "stream_started", %{
      stream: PodWeb.StreamController.format_stream_public(stream)
    })
  end

  @doc """
  Called when a stream ends — removes it from listeners' feeds.
  """
  def stream_ended(stream_id) do
    PodWeb.Endpoint.broadcast("feed:all", "stream_ended", %{
      stream_id: stream_id
    })
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}
end
