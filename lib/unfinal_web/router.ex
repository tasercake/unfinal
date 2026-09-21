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
    plug :redirect_moved_document
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
    live "/live", LiveLive
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

  defp redirect_moved_document(
         %Plug.Conn{method: method, request_path: "/n/" <> _suffix} = conn,
         _opts
       )
       when method in ["GET", "HEAD"] do
    storage_path = String.replace_prefix(conn.request_path, "/n", "")

    case Unfinal.Documents.resolve_path(storage_path) do
      {:redirect, target_path} ->
        location = append_query_string("/n" <> target_path, conn.query_string)

        conn
        |> Plug.Conn.put_status(:moved_permanently)
        |> Phoenix.Controller.redirect(to: location)
        |> Plug.Conn.halt()

      _other ->
        conn
    end
  end

  defp redirect_moved_document(conn, _opts), do: conn

  defp append_query_string(path, ""), do: path
  defp append_query_string(path, query_string), do: path <> "?" <> query_string

  # Other scopes may use custom stacks.
  # scope "/api", UnfinalWeb do
  #   pipe_through :api
  # end
end
