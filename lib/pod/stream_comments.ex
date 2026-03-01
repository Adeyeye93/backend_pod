defmodule Pod.StreamComments do
  @moduledoc """
  The StreamComments context.

  Handles live stream comments — creating, fetching, and liking.
  Comments are tied to both a LiveStream and a Creator (the commenter).

  Note: the belongs_to associations in StreamComment are currently commented
  out in the schema. They should be uncommented — the foreign key fields
  live_stream_id and creator_id are already there, the associations just make
  preloading cleaner.
  """

  import Ecto.Query
  alias Pod.Repo
  alias Pod.Stream.StreamComment

  # ---------------------------------------------------------------------------
  # Creating comments
  # ---------------------------------------------------------------------------

  @doc """
  Posts a comment on a live stream.

  Called from your Phoenix Channel when a listener sends a chat message.
  Only valid while the stream is live — you should guard this at the
  Channel level by checking stream status before calling here.
  """
  def create_comment(attrs) do
    %StreamComment{}
    |> StreamComment.changeset(attrs)
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Fetching comments
  # ---------------------------------------------------------------------------

  @doc """
  Gets recent comments for a live stream, ordered oldest to newest.

  Limits to the last 50 by default — enough for a listener joining mid-stream
  to see recent chat context without loading the entire history.
  """
  def list_recent_comments(live_stream_id, limit \\ 50) do
    StreamComment
    |> where([c], c.live_stream_id == ^live_stream_id)
    |> order_by([c], asc: c.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets all comments for a stream after a given datetime.

  Used for paginating live chat — fetch only comments newer than the
  last one the client already has.
  """
  def list_comments_since(live_stream_id, since_datetime) do
    StreamComment
    |> where([c], c.live_stream_id == ^live_stream_id)
    |> where([c], c.inserted_at > ^since_datetime)
    |> order_by([c], asc: c.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets the total comment count for a stream.
  Useful for engagement stats when the stream ends.
  """
  def count_comments(live_stream_id) do
    StreamComment
    |> where([c], c.live_stream_id == ^live_stream_id)
    |> Repo.aggregate(:count, :id)
  end

  # ---------------------------------------------------------------------------
  # Likes
  # ---------------------------------------------------------------------------

  @doc """
  Increments the like count on a comment by 1.
  Called when a listener taps the like button on a comment.
  """
  def like_comment(comment_id) do
    case Repo.get(StreamComment, comment_id) do
      nil ->
        {:error, :not_found}

      comment ->
        comment
        |> StreamComment.changeset(%{likes: comment.likes + 1})
        |> Repo.update()
    end
  end
end
