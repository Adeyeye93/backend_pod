defmodule PodWeb.GuestInviteJSON do
  alias Pod.Stream.GuestInvite

  def index(%{invites: invites}) do
    %{invites: Enum.map(invites, &data/1)}
  end

  def show(%{invite: invite}) do
    %{invite: data(invite)}
  end

  defp data(%GuestInvite{} = invite) do
    %{
      id:                   invite.id,
      status:               invite.status,
      role:                 invite.role,
      message:              invite.message,
      live_stream_id:       invite.live_stream_id,
      host_creator_id:      invite.host_creator_id,
      guest_creator_id:     invite.guest_creator_id,
      scheduled_start_time: invite.scheduled_start_time,
      invite_sent_at:       invite.invite_sent_at,
      accepted_at:          invite.accepted_at,
      declined_at:          invite.declined_at,
      joined_at:            invite.joined_at,
      inserted_at:          invite.inserted_at,
      host_creator:         maybe_host_creator(invite),
      guest_creator:        maybe_guest_creator(invite),
      live_stream:          maybe_live_stream(invite)
    }
  end

  defp maybe_host_creator(%{host_creator: %{id: _} = c}),
    do: %{id: c.id, channel_name: c.name, avatar_url: c.avatar, channel_id: c.channel_id}
  defp maybe_host_creator(_), do: nil

  defp maybe_guest_creator(%{guest_creator: %{id: _} = c}),
    do: %{id: c.id, channel_name: c.name, avatar_url: c.avatar, channel_id: c.channel_id}
  defp maybe_guest_creator(_), do: nil

  defp maybe_live_stream(%{live_stream: %{id: _} = s}),
    do: %{
      id:                   s.id,
      title:                s.title,
      thumbnail:            s.thumbnail,
      scheduled_start_time: s.scheduled_start_time,
      status:               s.status
    }
  defp maybe_live_stream(_), do: nil
end
