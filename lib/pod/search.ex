defmodule Pod.Search do
  import Ecto.Query
  alias Pod.Repo
  alias Pod.Stream.LiveStream
  alias Pod.Stream.Creator

  @doc """
  Full-text search across ended/recorded streams.
  Matches title, description, category, creator name, or tags.
  Exact title matches are ranked first; all others follow.
  """
  def search_recordings(query, limit \\ 20) do
    q     = "%#{query}%"
    exact = String.downcase(query)

    LiveStream
    |> where([s],
      s.status == "ended" and
        s.record_stream == true and
        s.is_private == false and
        not is_nil(s.download_url)
    )
    |> join(:inner, [s], c in Creator, on: c.id == s.creator_id)
    |> where(
      [s, c],
      ilike(s.title, ^q) or
        ilike(s.description, ^q) or
        ilike(s.category, ^q) or
        ilike(c.name, ^q) or
        fragment("array_to_string(?, ',') ILIKE ?", s.tags, ^q)
    )
    |> order_by([s, _c],
      fragment("CASE WHEN lower(?) = ? THEN 0 ELSE 1 END", s.title, ^exact)
    )
    |> limit(^limit)
    |> preload(:creator)
    |> Repo.all()
  end

  @doc """
  Searches creators by name or bio.
  Returns {creators, live_creator_ids} so the caller can mark is_live without N+1.
  """
  def search_creators(query, limit \\ 10) do
    q     = "%#{query}%"
    exact = String.downcase(query)

    creators =
      Creator
      |> where([c], c.is_active == true)
      |> where([c], ilike(c.name, ^q) or ilike(c.bio, ^q))
      |> order_by([c],
        fragment("CASE WHEN lower(?) = ? THEN 0 ELSE 1 END", c.name, ^exact)
      )
      |> limit(^limit)
      |> Repo.all()

    live_ids =
      if creators == [] do
        MapSet.new()
      else
        ids = Enum.map(creators, & &1.id)

        LiveStream
        |> where([s], s.status == "live" and s.creator_id in ^ids)
        |> select([s], s.creator_id)
        |> Repo.all()
        |> MapSet.new()
      end

    {creators, live_ids}
  end
end
