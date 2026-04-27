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
      id:                  invite.id,
      status:              invite.status,
      role:                invite.role,
      message:             invite.message,
      live_stream_id:      invite.live_stream_id,
      host_creator_id:     invite.host_creator_id,
      guest_creator_id:    invite.guest_creator_id,
      scheduled_start_time: invite.scheduled_start_time,
      invite_sent_at:      invite.invite_sent_at,
      accepted_at:         invite.accepted_at,
      declined_at:         invite.declined_at,
      joined_at:           invite.joined_at,
      inserted_at:         invite.inserted_at,
      # Include preloaded associations if present
      host_creator:        maybe_creator(invite),
      guest_creator:       maybe_guest(invite)
    }
  end

  defp maybe_creator(%{host_creator: %{id: _} = creator}),
    do: %{id: creator.id, name: creator.name, avatar: creator.avatar, channel_id: creator.channel_id}
  defp maybe_creator(_), do: nil

  defp maybe_guest(%{guest_creator: %{id: _} = creator}),
    do: %{id: creator.id, name: creator.name, avatar: creator.avatar, channel_id: creator.channel_id}
  defp maybe_guest(_), do: nil
end
