defmodule Pod.Stream.CreatorSerializer do
  def serialize(%Pod.Stream.Creator{} = creator) do
    %{
      id: creator.id,
      channel_id: creator.channel_id,
      name: creator.name,
      avatar: creator.avatar,
      bio: creator.bio,
      follower_count: creator.follower_count,
      is_active: creator.is_active
    }
  end
end
