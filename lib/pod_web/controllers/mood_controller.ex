defmodule PodWeb.MoodController do
   use PodWeb, :controller
  alias Pod.Mood

  # Get all interests
  def moodIndex(conn, _params) do
    moods = Mood.list_moods()
  render(conn, :moodIndex, moods: moods)
  end

  # Save user interests
# def save_user_interests(conn, %{"user_id" => user_id, "interest_ids" => interest_ids}) do
#   case Interests.update_user_interests(user_id, interest_ids) do
#     {:ok, %{added: _count, total: total}} ->
#       json(conn, %{
#         success: true,
#         interests_saved: total,
#         interests_selected_at: NaiveDateTime.utc_now()
#       })

#     {:error, reason} ->
#       json(conn, %{success: false, error: reason})
#   end
# end

#   # Get user interests
#   def get_user_interests(conn, %{"user_id" => user_id}) do
#     interests = Interests.get_user_interests(user_id)
#     json(conn, %{interests: interests})
#   end
end
