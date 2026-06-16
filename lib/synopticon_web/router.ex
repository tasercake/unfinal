defmodule SynopticonWeb.Router do
  use SynopticonWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SynopticonWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SynopticonWeb do
    pipe_through :browser

    live "/", EditorLive
    post "/login", SessionController, :create
    live "/*path", EditorLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", SynopticonWeb do
  #   pipe_through :api
  # end
end
