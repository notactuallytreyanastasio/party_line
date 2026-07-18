defmodule PartyLineWeb.Router do
  use PartyLineWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PartyLineWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PartyLineWeb.Plugs.Voter
    plug PartyLineWeb.Plugs.CurrentIdentity
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # the public completion API: OpenAI/Anthropic-shaped, keyed by an
  # atproto-bound bearer token (PartyLineWeb.Plugs.ApiAuth)
  pipeline :completion_api do
    plug :accepts, ["json"]
    plug PartyLineWeb.Plugs.ApiAuth
  end

  scope "/", PartyLineWeb do
    pipe_through :browser

    live "/", LandingLive
    live "/tour", TourLive
    live "/ask", AskLive
    live "/keys", KeysLive
    live "/line", RoomLive, :switchboard
    live "/stumble", RoomLive, :stumble
    live "/host", HostLive
    # the boards: the reddit-esque posts site (bot posts, votes, hot)
    live "/boards", FrontpageLive, :front
    live "/boards/b/:board", FrontpageLive, :board
    live "/boards/:id", FrontpageLive, :show
    # the wall: humans' clipped chat exchanges (a different thing)
    live "/wall", BoardsLive, :index
    live "/wall/:id", BoardsLive, :show

    # atproto OAuth (sign in with your handle — no app passwords)
    post "/oauth/login", OAuthController, :login
    get "/oauth/callback", OAuthController, :callback
    post "/oauth/logout", OAuthController, :logout
    get "/oauth/client-metadata.json", OAuthController, :client_metadata
  end

  scope "/api", PartyLineWeb do
    pipe_through :api

    post "/dial", DialController, :dial

    # public discovery read — names/models only, never addresses
    get "/hosts", HostController, :index
  end

  # Lending a model is a privileged, identity-bound act: registration and
  # liveness are keyed to the same atproto-bound token the completion API uses,
  # so a host is owned by a did and can't be squatted anonymously.
  scope "/api", PartyLineWeb do
    pipe_through :completion_api

    post "/hosts/register", HostController, :register
    post "/hosts/:id/heartbeat", HostController, :heartbeat
    delete "/hosts/:id", HostController, :deregister
  end

  # OpenAI/Anthropic-compatible completion API over the federated exchange.
  scope "/v1", PartyLineWeb do
    pipe_through :completion_api

    post "/chat/completions", ChatCompletionsController, :create
    post "/messages", MessagesController, :create
    get "/models", ModelsController, :index
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:party_line, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PartyLineWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
