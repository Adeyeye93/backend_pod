defmodule PodWeb.FeedController do
  use PodWeb, :controller

  alias Pod.Feed
  alias Pod.Accounts.Guardian

  def home(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    sections = Feed.home_feed(user)

    conn
    |> put_status(:ok)
    |> json(%{sections: sections})
  end
end
