defmodule Pod.ListeningHistory do
  import Ecto.Query
  alias Pod.Repo
  alias Pod.ListeningHistory.ListeningHistory

  @recents_limit 5

  # ---------------------------------------------------------------------------
  # Record progress — upserts so each stream has one row per user
  # ---------------------------------------------------------------------------

  def record_progress(user_id, live_stream_id, progress_seconds, completed \\ false) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      user_id:          user_id,
      live_stream_id:   live_stream_id,
      progress_seconds: progress_seconds,
      completed:        completed,
      last_listened_at: now
    }

    case Repo.get_by(ListeningHistory, user_id: user_id, live_stream_id: live_stream_id) do
      nil ->
        %ListeningHistory{}
        |> ListeningHistory.changeset(attrs)
        |> Repo.insert()

      %ListeningHistory{} = existing ->
        existing
        |> ListeningHistory.changeset(attrs)
        |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  def get_progress(user_id, live_stream_id) do
    Repo.get_by(ListeningHistory, user_id: user_id, live_stream_id: live_stream_id)
  end

  @doc """
  Returns recent in-progress recordings ordered by most recently played.
  Excludes completed items (progress_seconds = 0) and recordings not yet packaged.
  """
  def list_recent(user_id, limit \\ @recents_limit) do
    ListeningHistory
    |> join(:inner, [lh], s in assoc(lh, :live_stream))
    |> where([lh, s],
      lh.user_id == ^user_id and
        lh.progress_seconds > 0 and
        not is_nil(s.download_url)
    )
    |> order_by([lh], desc: lh.last_listened_at)
    |> limit(^limit)
    |> preload(live_stream: :creator)
    |> Repo.all()
  end

  @doc "Returns a map of %{live_stream_id => progress_seconds} for the given user and stream IDs."
  def get_progress_map(_user_id, []), do: %{}
  def get_progress_map(user_id, stream_ids) do
    ListeningHistory
    |> where([lh], lh.user_id == ^user_id and lh.live_stream_id in ^stream_ids)
    |> select([lh], {lh.live_stream_id, lh.progress_seconds})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Returns the most recently listened-to session timestamp, or nil."
  def last_session_at(user_id) do
    ListeningHistory
    |> where([lh], lh.user_id == ^user_id)
    |> select([lh], max(lh.last_listened_at))
    |> Repo.one()
  end

  @doc "Returns distinct categories from the user's listening history."
  def listened_categories(user_id) do
    ListeningHistory
    |> where([lh], lh.user_id == ^user_id)
    |> join(:inner, [lh], s in assoc(lh, :live_stream))
    |> select([_lh, s], s.category)
    |> distinct(true)
    |> Repo.all()
  end
end
