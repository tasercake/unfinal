defmodule UnfinalWeb.Router do
  use UnfinalWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {UnfinalWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", UnfinalWeb do
    pipe_through :browser

    get "/", SessionController, :root
    get "/login", SessionController, :login
    get "/logout", SessionController, :logout
    post "/logout", SessionController, :logout
    live "/claim", ClaimLive
    live "/n", EditorLive
    live "/n/*path", EditorLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", UnfinalWeb do
  #   pipe_through :api
  # end
end
