defmodule PodWeb.StreamChannel do
  use Phoenix.Channel
  require Logger

  alias Pod.Stream
  alias Pod.StreamComments
  alias Pod.Creators

  # ---------------------------------------------------------------------------
  # Join
  #
  # Topic format: "stream:{live_stream_id}"
  #
  # Both broadcasters and listeners join the same topic.
  # We check whether the stream exists and is accessible before allowing join.
  # ---------------------------------------------------------------------------

  @impl true
  def join("stream:" <> stream_id, _params, socket) do
    case Stream.get_stream(stream_id) do
      nil ->
        {:error, %{reason: "stream_not_found"}}

      stream when stream.is_private ->
        # Private stream — only allow if user is the creator or an invited guest
        user_id = socket.assigns.user_id

        if authorized_for_private?(stream, user_id) do
          socket = assign(socket, :stream_id, stream_id)
          send(self(), :after_join)
          {:ok, %{stream_id: stream_id}, socket}
        else
          {:error, %{reason: "private_stream"}}
        end

      stream ->
        socket = assign(socket, :stream_id, stream.id)
        send(self(), :after_join)
        {:ok, %{stream_id: stream.id, status: stream.status}, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # After join — send the joining user initial state
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:after_join, socket) do
    stream_id = socket.assigns.stream_id

    # Send recent comments so new joiners see chat history
    comments = StreamComments.list_recent_comments(stream_id, 30)

    push(socket, "recent_comments", %{
      comments: Enum.map(comments, &format_comment/1)
    })

    # Send current stream status
    case Stream.get_stream(stream_id) do
      nil ->
        {:noreply, socket}

      stream ->
        push(socket, "stream_state", %{
          status: stream.status,
          viewer_count: stream.viewer_count,
          title: stream.title
        })

        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Incoming messages from clients
  # ---------------------------------------------------------------------------

  @doc """
  A listener or guest posts a comment during a live stream.

  Expected payload: %{"text" => "..."}
  The creator_id is resolved from the authenticated user_id on the socket.
  """
  @impl true
  def handle_in("new_comment", %{"text" => text}, socket) do
    stream_id = socket.assigns.stream_id
    user_id = socket.assigns.user_id

    # Resolve creator from user_id
    case Creators.get_creator_by_user(user_id) do
      nil ->
        {:reply, {:error, %{reason: "creator_profile_not_found"}}, socket}

      creator ->
        case StreamComments.create_comment(%{
               live_stream_id: stream_id,
               creator_id: creator.id,
               text: text
             }) do
          {:ok, comment} ->
            # Broadcast the comment to everyone on this stream topic
            broadcast!(socket, "new_comment", format_comment(comment, creator))
            {:reply, :ok, socket}

          {:error, changeset} ->
            {:reply, {:error, %{errors: format_errors(changeset)}}, socket}
        end
    end
  end

  # @doc """
  # Broadcaster signals they are ending the stream.
  # Only the stream creator can send this.
  # """
  def handle_in("end_stream", _params, socket) do
    stream_id = socket.assigns.stream_id
    user_id = socket.assigns.user_id

    with stream <- Stream.get_stream(stream_id),
         true <- authorized_as_creator?(stream, user_id) do
      case Stream.end_stream(stream) do
        {:ok, _updated} ->
          # Notify all listeners the stream has ended
          broadcast!(socket, "stream_ended", %{stream_id: stream_id})
          {:reply, :ok, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: inspect(reason)}}, socket}
      end
    else
      _ -> {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  # @doc """
  # Called by the server (from Season) to notify listeners that a new
  # segment is available at a given URL.

  # This is the key signalling message — listeners receive this and their
  # player fetches the segment from the CDN/local server.

  # Note: this is pushed FROM the server using broadcast_from_server/2,
  # not sent by a client. Clients sending this message are ignored.
  # """
  def handle_in("segment_ready", _params, socket) do
    # Clients cannot push segment_ready — only the server can
    {:reply, {:error, %{reason: "not_allowed"}}, socket}
  end

  # ---------------------------------------------------------------------------
  # Server-side broadcasts
  # Called from Season and Segmenter, not from client messages
  # ---------------------------------------------------------------------------

  @doc """
  Called by the Segmenter after writing a segment to notify all listeners.

  segments = %{
    128 => "http://yourserver/segments/stream_id/128k/segment_001.aac",
    192 => "http://yourserver/segments/stream_id/192k/segment_001.aac",
    320 => "http://yourserver/segments/stream_id/320k/segment_001.aac"
  }
  """
  def notify_segment_ready(stream_id, segment_number, segment_urls) do
    PodWeb.Endpoint.broadcast("stream:#{stream_id}", "segment_ready", %{
      segment: segment_number,
      urls: %{
        low: segment_urls[128],
        medium: segment_urls[192],
        high: segment_urls[320]
      }
    })
  end

  @doc """
  Called by Season when viewer count changes (via Phoenix Presence or manual tracking).
  """
  def notify_viewer_count(stream_id, count) do
    PodWeb.Endpoint.broadcast("stream:#{stream_id}", "viewer_count", %{count: count})
  end

  @doc """
  Called when a guest invite is accepted — notifies the host's client.
  """
  def notify_guest_accepted(stream_id, guest_creator) do
    PodWeb.Endpoint.broadcast("stream:#{stream_id}", "guest_accepted", %{
      creator_id: guest_creator.id,
      name: guest_creator.name,
      avatar: guest_creator.avatar
    })
  end

  # ---------------------------------------------------------------------------
  # Terminate
  # ---------------------------------------------------------------------------

  @impl true
  def terminate(reason, socket) do
    Logger.debug("[StreamChannel] Client left stream:#{socket.assigns[:stream_id]} — #{inspect(reason)}")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp authorized_for_private?(stream, user_id) do
    case Creators.get_creator_by_user(user_id) do
      nil -> false
      creator -> creator.id == stream.creator_id
    end
  end

  defp authorized_as_creator?(stream, user_id) do
    case Creators.get_creator_by_user(user_id) do
      nil -> false
      creator -> creator.id == stream.creator_id
    end
  end

  defp format_comment(comment, creator \\ nil) do
    %{
      id: comment.id,
      text: comment.text,
      likes: comment.likes,
      creator_id: comment.creator_id,
      creator_name: creator && creator.name,
      creator_avatar: creator && creator.avatar,
      inserted_at: comment.inserted_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
