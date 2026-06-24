defmodule UnfinalWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :unfinal

  @session_options [
    store: :cookie,
    key: "_unfinal_key",
    signing_salt: "KOV7UCMl",
    same_site: "Lax"
  ]

  @doc """
  Returns session options resolved at runtime so encryption_salt and
  secure can vary per environment.
  """
  def session_options do
    encryption_salt = Application.get_env(:unfinal, :encryption_salt)
    secure = Application.get_env(:unfinal, :secure_session_cookie, false)

    @session_options
    |> then(fn opts ->
      if encryption_salt, do: Keyword.put(opts, :encryption_salt, encryption_salt), else: opts
    end)
    |> Keyword.put(:secure, secure)
  end

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {UnfinalWeb.Endpoint, :session_options, []}]],
    longpoll: [connect_info: [session: {UnfinalWeb.Endpoint, :session_options, []}]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :unfinal,
    gzip: false,
    only: UnfinalWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug :redirect_trailing_slash
  plug UnfinalWeb.Plug.SessionLoader
  plug UnfinalWeb.Router

  defp redirect_trailing_slash(%Plug.Conn{request_path: "/"} = conn, _opts), do: conn

  defp redirect_trailing_slash(
         %Plug.Conn{request_path: path, query_string: query_string} = conn,
         _opts
       ) do
    if String.ends_with?(path, "/") do
      conn
      |> Plug.Conn.put_resp_header(
        "location",
        path |> String.trim_trailing("/") |> append_query_string(query_string)
      )
      |> Plug.Conn.send_resp(:moved_permanently, "")
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  defp append_query_string(path, ""), do: path
  defp append_query_string(path, query_string), do: path <> "?" <> query_string
end
