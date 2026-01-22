defmodule PodWeb.Router do
  use PodWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", PodWeb do
    pipe_through :api
  end

  pipeline :jwt_authenticated do
  plug :accepts, ["json"]

  plug Guardian.Plug.Pipeline,
    module: Pod.Accounts.Guardian,
    error_handler: PodWeb.AuthErrorHandler

  plug Guardian.Plug.VerifySession, claims: %{"typ" => "access"}
  plug Guardian.Plug.VerifyHeader, claims: %{"typ" => "access"}
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource
end


  scope "/api", PodWeb do
    pipe_through :api

    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
    post "/auth/refresh", AuthController, :refresh
    post "/auth/social/google", AuthController, :google_login
    post "/auth/social/apple", AuthController, :apple_login
  end

  scope "/api", PodWeb do
    pipe_through :jwt_authenticated

    delete "/auth/logout", AuthController, :logout
    get "/interests", InterestsController, :index
    get "/users/:user_id/interests", InterestsController, :get_user_interests
    post "/users/:user_id/interests/save", InterestsController, :save_user_interests
    get "/get_mood", MoodController, :moodIndex
    get "/set_am_a_creator/:user_id", UserActivityController, :set_am_a_creator
    # Add your protected routes here
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:pod, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: PodWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
