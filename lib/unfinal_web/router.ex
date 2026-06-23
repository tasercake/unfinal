defmodule UnfinalWeb.Router do
  use UnfinalWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {UnfinalWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :validate_document_path
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", UnfinalWeb do
    pipe_through :browser

    get "/", SessionController, :root
    get "/login", SessionController, :login
    get "/auth/clerk/callback", SessionController, :clerk_callback
    get "/logout", SessionController, :logout
    post "/logout", SessionController, :logout
    live "/claim", ClaimLive
    live "/n", EditorLive
    live "/n/*path", EditorLive
  end

  defp validate_document_path(%Plug.Conn{request_path: "/n"} = conn, _opts), do: conn

  defp validate_document_path(%Plug.Conn{request_path: "/n/" <> suffix} = conn, _opts) do
    segments = String.split(suffix, "/")

    if Unfinal.DocumentPath.valid_segments?(segments) do
      conn
    else
      conn
      |> Plug.Conn.put_status(:not_found)
      |> Phoenix.Controller.put_view(html: UnfinalWeb.ErrorHTML)
      |> Phoenix.Controller.render(:"404")
      |> Plug.Conn.halt()
    end
  end

  defp validate_document_path(conn, _opts), do: conn

  # Other scopes may use custom stacks.
  # scope "/api", UnfinalWeb do
  #   pipe_through :api
  # end
end
