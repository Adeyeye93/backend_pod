defmodule Pod.Feed do
  @moduledoc """
  Home feed assembly.

  All six independent DB fetches run in parallel via Task.await_many/2.
  Sections are built in priority order and empty ones are dropped before
  the list is returned to the controller.
  """

  import Ecto.Query
  alias Pod.Repo
  alias Pod.Stream.{LiveStream, Creator}
  alias Pod.Accounts.{User, UserInterest}
  alias Pod.Follows
  alias Pod.ListeningHistory
  alias Pod.Creators
  alias Pod.ListeningPresence

  @live_limit        5
  @recordings_limit  10
  @suggestion_limit  6
  @recents_limit     5
  @trending_limit    10

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------

  def home_feed(user) do
    creator        = Creators.get_creator_by_user(user.id)
    interest_names = fetch_interest_names(user.id)
    storage        = storage_config()

    # Kick off all independent fetches concurrently
    [
      followed_ids,
      followed_creators,
      live,
      recordings,
      suggestions,
      interest_streams,
      creator_streams,
      recents,
      last_session,
      listened_categories,
      trending
    ] =
      [
        Task.async(fn -> Follows.list_followed_creator_ids(user.id) end),
        Task.async(fn -> Follows.list_followed_creators(user.id) end),
        Task.async(fn -> fetch_live_streams() end),
        Task.async(fn -> fetch_recordings(@recordings_limit) end),
        Task.async(fn -> fetch_suggestions(@suggestion_limit) end),
        Task.async(fn -> fetch_by_interests(interest_names, @suggestion_limit) end),
        Task.async(fn -> fetch_creator_streams(creator, @suggestion_limit) end),
        Task.async(fn -> ListeningHistory.list_recent(user.id, @recents_limit) end),
        Task.async(fn -> ListeningHistory.last_session_at(user.id) end),
        Task.async(fn -> ListeningHistory.listened_categories(user.id) end),
        Task.async(fn -> fetch_trending(@trending_limit) end)
      ]
      |> Task.await_many(5_000)

    followed_recordings = fetch_followed_recordings(followed_ids, @recordings_limit)
    recent_session?     = recent_session?(last_session)

    [
      subscriptions_section(followed_creators, live),
      recents_section(recents, recent_session?, storage),
      live_section(live, storage),
      recordings_or_fallback(followed_recordings, recordings, suggestions, storage),
      your_shows_section(creator, creator_streams),
      channel_recommendation_section(followed_creators, listened_categories, followed_ids, live),
      popular_with_listeners_of_section(followed_creators, listened_categories, followed_ids, live),
      interests_section(interest_names, interest_streams, storage),
      trending_section(trending, storage)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  defp fetch_interest_names(user_id) do
    UserInterest
    |> where([ui], ui.user_id == ^user_id)
    |> join(:inner, [ui], i in assoc(ui, :interest))
    |> select([_ui, i], i.name)
    |> Repo.all()
  end

  defp fetch_live_streams do
    LiveStream
    |> where([s], s.status == "live" and s.is_private == false)
    |> preload(:creator)
    |> order_by([s], desc: s.viewer_count)
    |> limit(@live_limit)
    |> Repo.all()
  end

  defp fetch_recordings(limit) do
    LiveStream
    |> where([s], s.status == "ended" and s.record_stream == true and s.is_private == false)
    |> preload(:creator)
    |> order_by([s], desc: s.end_time)
    |> limit(^limit)
    |> Repo.all()
  end

  # Followed recordings — new episodes from creators the user follows
  defp fetch_followed_recordings([], _limit), do: []

  defp fetch_followed_recordings(creator_ids, limit) do
    LiveStream
    |> where([s],
        s.creator_id in ^creator_ids and
        s.status == "ended" and
        s.record_stream == true and
        s.is_private == false
       )
    |> preload(:creator)
    |> order_by([s], desc: s.end_time)
    |> limit(^limit)
    |> Repo.all()
  end

  defp fetch_suggestions(limit) do
    LiveStream
    |> where([s], s.status == "ended" and s.record_stream == true and s.is_private == false)
    |> preload(:creator)
    |> order_by([s], [desc: s.peak_viewers, desc: s.total_viewers])
    |> limit(^limit)
    |> Repo.all()
  end

  defp fetch_by_interests([], _limit), do: []

  defp fetch_by_interests(names, limit) do
    LiveStream
    |> where([s],
        s.status == "ended" and
        s.record_stream == true and
        s.is_private == false and
        s.category in ^names
       )
    |> preload(:creator)
    |> order_by([s], desc: s.end_time)
    |> limit(^limit)
    |> Repo.all()
  end

  defp fetch_creator_streams(nil, _limit), do: []

  defp fetch_creator_streams(%Creator{id: creator_id}, limit) do
    LiveStream
    |> where([s], s.creator_id == ^creator_id and s.status == "ended" and s.record_stream == true)
    |> order_by([s], desc: s.end_time)
    |> limit(^limit)
    |> Repo.all()
  end

  defp fetch_trending(limit) do
    LiveStream
    |> where([s], s.status == "ended" and s.record_stream == true and s.is_private == false)
    |> preload(:creator)
    |> order_by([s], [desc: s.peak_viewers, desc: s.total_viewers])
    |> limit(^limit)
    |> Repo.all()
  end

  # Recommend creators in listened-to categories that the user doesn't already follow
  defp fetch_recommended_creators(categories, followed_ids, limit) do
    Creator
    |> join(:inner, [c], s in assoc(c, :live_streams))
    |> where([c, s], s.category in ^categories and c.id not in ^followed_ids and c.is_active == true)
    |> distinct([c], c.id)
    |> order_by([c], desc: c.follower_count)
    |> limit(^limit)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Section builders
  # ---------------------------------------------------------------------------

  defp subscriptions_section(followed_creators, live) do
    live_ids = MapSet.new(live, & &1.creator_id)

    items =
      Enum.map(followed_creators, fn creator ->
        %{
          id:            creator.id,
          name:          creator.name,
          thumbnail_url: creator.avatar,
          is_live:       MapSet.member?(live_ids, creator.id)
        }
      end)

    %{
      id:            "subscriptions",
      type:          "subscriptions",
      title:         "Following",
      subtitle:      nil,
      reason:        nil,
      see_all_route: "/subscriptions",
      max_items:     20,
      channel:       nil,
      items:         items
    }
  end

  defp recents_section([], _recent?, _storage), do: nil
  defp recents_section(_, false, _storage), do: nil

  defp recents_section(histories, _recent?, storage) do
    items =
      Enum.map(histories, fn h ->
        s = h.live_stream
        creator = loaded_creator(s.creator)

        %{
          id:               s.id,
          title:            s.title,
          creator_name:     creator && creator.name,
          thumbnail_url:    s.thumbnail,
          master_url:       master_url(s.id, storage),
          duration_seconds: s.duration_seconds,
          progress_seconds: h.progress_seconds
        }
      end)

    %{
      id:            "recents",
      type:          "recents",
      title:         "Continue Listening",
      subtitle:      nil,
      reason:        nil,
      see_all_route: nil,
      max_items:     @recents_limit,
      channel:       nil,
      items:         items
    }
  end

  defp live_section([], _storage), do: nil

  defp live_section(streams, _storage) do
    %{
      id:            "live_streams",
      type:          "live_streams",
      title:         "Live Now",
      subtitle:      "Happening right now",
      reason:        nil,
      see_all_route: "/streams/live",
      max_items:     @live_limit,
      channel:       nil,
      items:         Enum.map(streams, &format_live_item/1)
    }
  end

  # Followed recordings takes priority over general recordings, which beats suggestions
  defp recordings_or_fallback(followed, general, suggestions, storage) do
    cond do
      followed != [] ->
        %{
          id:            "recordings",
          type:          "recordings",
          title:         "New Episodes",
          subtitle:      "From creators you follow",
          reason:        nil,
          see_all_route: "/streams/recorded",
          max_items:     @recordings_limit,
          channel:       nil,
          items:         Enum.map(followed, &format_recording_item(&1, storage))
        }

      general != [] ->
        %{
          id:            "recordings",
          type:          "recordings",
          title:         "New Episodes",
          subtitle:      "Latest recordings",
          reason:        nil,
          see_all_route: "/streams/recorded",
          max_items:     @recordings_limit,
          channel:       nil,
          items:         Enum.map(general, &format_recording_item(&1, storage))
        }

      suggestions != [] ->
        %{
          id:            "shows_you_might_like",
          type:          "shows_you_might_like",
          title:         "Shows You Might Like",
          subtitle:      "Popular with listeners",
          reason:        nil,
          see_all_route: "/streams/recorded",
          max_items:     @suggestion_limit,
          channel:       nil,
          items:         Enum.map(suggestions, &format_recording_item(&1, storage))
        }

      true -> nil
    end
  end

  defp your_shows_section(_creator, []), do: nil
  defp your_shows_section(nil, _streams), do: nil

  defp your_shows_section(_creator, streams) do
    %{
      id:            "your_shows",
      type:          "your_shows",
      title:         "Your Shows",
      subtitle:      nil,
      reason:        nil,
      see_all_route: "/streams/my",
      max_items:     @suggestion_limit,
      channel:       nil,
      items:         Enum.map(streams, &format_your_show_item/1)
    }
  end

  defp channel_recommendation_section([], _categories, _followed_ids, _live), do: nil
  defp channel_recommendation_section(_followed, [], _followed_ids, _live), do: nil

  defp channel_recommendation_section(_followed, categories, followed_ids, live) do
    creators = fetch_recommended_creators(categories, followed_ids, @suggestion_limit)

    if creators == [] do
      nil
    else
      live_ids = MapSet.new(live, & &1.creator_id)
      top_category = List.first(categories)

      %{
        id:            "channel_recommendation",
        type:          "channel_recommendation",
        title:         "Channels You Might Like",
        subtitle:      nil,
        reason:        "Based on your interest in #{top_category}",
        see_all_route: nil,
        max_items:     @suggestion_limit,
        channel:       nil,
        items:         Enum.map(creators, &format_creator_item(&1, live_ids))
      }
    end
  end

  defp popular_with_listeners_of_section([], _categories, _followed_ids, _live), do: nil
  defp popular_with_listeners_of_section(_followed, [], _followed_ids, _live), do: nil

  defp popular_with_listeners_of_section([anchor | _], categories, followed_ids, live) do
    # Recommend creators in the same categories as the anchor, excluding already followed
    creators = fetch_recommended_creators(categories, [anchor.id | followed_ids], @suggestion_limit)

    if creators == [] do
      nil
    else
      live_ids = MapSet.new(live, & &1.creator_id)

      %{
        id:            "popular_with_listeners_of",
        type:          "popular_with_listeners_of",
        title:         "Popular with Listeners of #{anchor.name}",
        subtitle:      nil,
        reason:        "Because you follow #{anchor.name}",
        see_all_route: nil,
        max_items:     @suggestion_limit,
        channel:       %{name: anchor.name, thumbnail_url: anchor.avatar},
        items:         Enum.map(creators, &format_creator_item(&1, live_ids))
      }
    end
  end

  defp interests_section([], _streams, _storage), do: nil
  defp interests_section(_names, [], _storage), do: nil

  defp interests_section(_names, streams, storage) do
    %{
      id:            "episodes_you_might_like",
      type:          "episodes_you_might_like",
      title:         "Made for You",
      subtitle:      "Based on your interests",
      reason:        nil,
      see_all_route: nil,
      max_items:     @suggestion_limit,
      channel:       nil,
      items:         Enum.map(streams, &format_recording_item(&1, storage))
    }
  end

  defp trending_section([], _storage), do: nil

  defp trending_section(streams, storage) do
    %{
      id:            "trending",
      type:          "trending",
      title:         "Trending",
      subtitle:      "Popular with listeners right now",
      reason:        nil,
      see_all_route: "/streams/recorded",
      max_items:     @trending_limit,
      channel:       nil,
      items:         Enum.map(streams, &format_recording_item(&1, storage))
    }
  end

  # ---------------------------------------------------------------------------
  # Item formatters
  # ---------------------------------------------------------------------------

  defp format_live_item(stream) do
    creator = loaded_creator(stream.creator)
    %{
      id:            stream.id,
      title:         stream.title,
      creator_name:  creator && creator.name,
      thumbnail_url: stream.thumbnail,
      viewer_count:  stream.viewer_count,
      started_at:    stream.actual_start_time
    }
  end

  defp format_recording_item(stream, storage) do
    creator = loaded_creator(stream.creator)

    effective_master_url =
      case stream.archive_path do
        url when is_binary(url) and url != "" -> url
        _ -> master_url(stream.id, storage)
      end

    %{
      id:               stream.id,
      title:            stream.title,
      creator_name:     creator && creator.name,
      creator_id:       stream.creator_id,
      thumbnail_url:    stream.thumbnail,
      master_url:       effective_master_url,
      download_url:     stream.download_url,
      duration_seconds: stream.duration_seconds,
      published_at:     stream.end_time
    }
  end

  defp format_your_show_item(stream) do
    %{
      id:                stream.id,
      title:             stream.title,
      thumbnail_url:     stream.thumbnail,
      episode_count:     1,
      last_published_at: stream.end_time
    }
  end

  defp format_creator_item(creator, live_ids) do
    %{
      id:             creator.id,
      name:           creator.name,
      thumbnail_url:  creator.avatar,
      is_live:        MapSet.member?(live_ids, creator.id),
      follower_count: creator.follower_count
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp recent_session?(nil), do: false

  defp recent_session?(last_at) do
    DateTime.diff(DateTime.utc_now(), last_at, :hour) < 24
  end

  defp loaded_creator(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded_creator(creator), do: creator

  defp master_url(stream_id, %{adapter: :s3, base_url: base}),
    do: "#{base}/broadcasters/#{stream_id}/master.m3u8"

  defp master_url(stream_id, %{base_url: base}),
    do: "#{base}/#{stream_id}/master.m3u8"

  defp storage_config do
    config = Application.get_env(:pod, :storage, [])
    %{
      adapter:  Keyword.get(config, :adapter, :local),
      base_url: Keyword.get(config, :base_url, "http://localhost:4000/segments")
    }
  end

  # ---------------------------------------------------------------------------
  # Listening-Now feed
  # ---------------------------------------------------------------------------

  @listening_now_limit   20
  @listener_preview_limit 3

  @doc """
  Returns active listening sessions ranked by relevance to `user`.

  Ranking tiers (ascending rank score, lower = better):
    "both"     — social signal AND interest match
    "interest" — interest match OR social signal alone
    "none"     — no signal

  Within each tier sessions are ordered by listener_count desc.
  """
  def listening_now(user) do
    recording_ids = Pod.ListeningRegistry.list_all()
    if recording_ids == [], do: [], else: do_listening_now(user, recording_ids)
  end

  defp do_listening_now(user, recording_ids) do
    sessions_raw =
      recording_ids
      |> Enum.map(fn id -> {id, ListeningPresence.list("listening:#{id}")} end)
      |> Enum.reject(fn {_id, p} -> map_size(p) == 0 end)

    if sessions_raw == [] do
      []
    else
      stream_ids       = Enum.map(sessions_raw, fn {id, _} -> id end)
      all_listener_ids = sessions_raw |> Enum.flat_map(fn {_, p} -> Map.keys(p) end) |> Enum.uniq()

      [streams_map, users_map] =
        [
          Task.async(fn -> load_streams_map(stream_ids) end),
          Task.async(fn -> load_users_map(all_listener_ids) end)
        ]
        |> Task.await_many(5_000)

      storage       = storage_config()
      interest_set  = fetch_interest_names(user.id) |> MapSet.new()
      social_ids    = build_social_set(user)

      sessions_raw
      |> Enum.map(fn {recording_id, presences} ->
        case Map.get(streams_map, recording_id) do
          nil    -> nil
          stream -> build_session_item(recording_id, presences, stream, users_map, interest_set, social_ids, storage)
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn s -> {match_rank(s.match), -s.listener_count} end)
      |> Enum.take(@listening_now_limit)
    end
  end

  defp build_session_item(recording_id, presences, stream, users_map, interest_set, social_ids, storage) do
    listener_pairs =
      Enum.map(presences, fn {uid, %{metas: metas}} ->
        meta     = List.last(metas)
        position = Map.get(meta, :current_position_seconds, 0)
        {uid, position}
      end)

    listener_ids = Enum.map(listener_pairs, fn {uid, _} -> uid end)

    avg_position =
      case listener_pairs do
        [] -> 0
        ps -> div(Enum.sum(Enum.map(ps, fn {_, p} -> p end)), length(ps))
      end

    listeners =
      listener_ids
      |> Enum.take(@listener_preview_limit)
      |> Enum.map(fn uid ->
        case Map.get(users_map, uid) do
          nil  -> %{user_id: uid, username: nil, avatar_url: nil}
          user -> %{user_id: uid, username: user.username, avatar_url: user.avatar_url}
        end
      end)

    creator = loaded_creator(stream.creator)

    %{
      recording_id:             recording_id,
      title:                    stream.title,
      thumbnail_url:            stream.thumbnail,
      master_url:               master_url(recording_id, storage),
      creator_id:               stream.creator_id,
      creator_name:             creator && creator.name,
      creator_avatar_url:       creator && creator.avatar,
      duration_seconds:         stream.duration_seconds,
      current_position_seconds: avg_position,
      listener_count:           length(listener_ids),
      listeners:                listeners,
      match:                    compute_match(listener_ids, stream.category, interest_set, social_ids)
    }
  end

  defp compute_match(listener_ids, category, interest_set, social_ids) do
    interest? = MapSet.member?(interest_set, category)
    social?   = Enum.any?(listener_ids, &MapSet.member?(social_ids, &1))

    cond do
      social? and interest? -> "both"
      social? or interest?  -> "interest"
      true                  -> "none"
    end
  end

  defp match_rank("both"),     do: 0
  defp match_rank("interest"), do: 1
  defp match_rank(_),          do: 2

  defp build_social_set(user) do
    followed_creator_ids = Follows.list_followed_creator_ids(user.id)

    followed_user_ids =
      if followed_creator_ids == [] do
        MapSet.new()
      else
        Creator
        |> where([c], c.id in ^followed_creator_ids)
        |> select([c], c.user_id)
        |> Repo.all()
        |> MapSet.new()
      end

    my_follower_ids =
      case Creators.get_creator_by_user(user.id) do
        nil     -> MapSet.new()
        creator -> Follows.list_follower_ids(creator.id) |> MapSet.new()
      end

    MapSet.union(followed_user_ids, my_follower_ids)
  end

  defp load_streams_map([]), do: %{}
  defp load_streams_map(ids) do
    LiveStream
    |> where([s], s.id in ^ids)
    |> preload(:creator)
    |> Repo.all()
    |> Map.new(fn s -> {s.id, s} end)
  end

  defp load_users_map([]), do: %{}
  defp load_users_map(ids) do
    from(u in User, where: u.id in ^ids)
    |> Repo.all()
    |> Map.new(fn u -> {u.id, u} end)
  end
end
