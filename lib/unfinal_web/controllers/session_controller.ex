defmodule UnfinalWeb.SessionController do
  use UnfinalWeb, :controller

  alias Unfinal.NamespaceStore

  @clerk_oauth_sessions_key :clerk_oauth_sessions
  @max_oauth_sessions 5
  @oauth_session_ttl_seconds 24 * 60 * 60

  def root(conn, _params), do: redirect(conn, to: ~p"/n")

  def login(conn, params) do
    return_to = safe_return_to(Map.get(params, "return_to"))
    start_clerk_oauth(conn, return_to)
  end

  def clerk_callback(conn, params), do: finish_clerk_oauth(conn, params)

  def logout(conn, params) do
    return_to = safe_return_to(Map.get(params, "return_to"))

    conn
    |> clear_session()
    |> redirect(to: return_to)
  end

  defp start_clerk_oauth(conn, return_to) do
    with {:ok, config} <- clerk_config(conn),
         {:ok, %{url: url, session_params: session_params}} <-
           clerk_oauth().authorize_url(config),
         state when is_binary(state) <- oauth_state(session_params) do
      entry = %{
        session_params: session_params,
        return_to: return_to,
        inserted_at: now()
      }

      sessions =
        conn
        |> get_oauth_sessions()
        |> Map.put(state, entry)
        |> keep_newest_oauth_sessions()

      conn
      |> put_oauth_sessions(sessions)
      |> redirect(external: url)
    else
      {:error, error} ->
        conn
        |> put_status(:service_unavailable)
        |> text("Clerk login unavailable: #{format_error(error)}")

      _error ->
        conn
        |> put_status(:service_unavailable)
        |> text("Clerk login unavailable")
    end
  end

  defp finish_clerk_oauth(conn, params) do
    state = Map.get(params, "state")
    sessions = get_oauth_sessions(conn)
    {entry, sessions} = if is_binary(state), do: Map.pop(sessions, state), else: {nil, sessions}
    conn = put_oauth_sessions(conn, sessions)

    with %{session_params: session_params, return_to: return_to} <- entry,
         {:ok, config} <- clerk_config(conn),
         config = Keyword.put(config, :session_params, session_params),
         {:ok, %{user: user}} <- clerk_oauth().callback(config, params),
         {:ok, app_user} <- user_from_clerk(user) do
      authenticate(conn, app_user, safe_return_to(return_to))
    else
      _error -> auth_failed(conn)
    end
  end

  defp clerk_config(_conn) do
    with {:ok, frontend_api_url} <- fetch_env("CLERK_FRONTEND_API_URL"),
         {:ok, client_id} <- fetch_env("CLERK_OAUTH_CLIENT_ID"),
         {:ok, client_secret} <- fetch_env("CLERK_OAUTH_CLIENT_SECRET") do
      redirect_uri =
        System.get_env("CLERK_OAUTH_REDIRECT_URI") ||
          url(~p"/auth/clerk/callback")

      scopes = System.get_env("CLERK_OAUTH_SCOPES") || "email profile"

      {:ok,
       [
         base_url: String.trim_trailing(frontend_api_url, "/"),
         openid_configuration_uri: "/.well-known/oauth-authorization-server",
         client_id: client_id,
         client_secret: client_secret,
         redirect_uri: redirect_uri,
         code_verifier: true,
         nonce: random_url_token(32),
         authorization_params: [scope: scopes],
         http_adapter: Assent.HTTPAdapter.Httpc
       ]}
    end
  end

  defp fetch_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, "missing #{name}"}
    end
  end

  defp random_url_token(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp get_oauth_sessions(conn) do
    case get_session(conn, @clerk_oauth_sessions_key) do
      sessions when is_map(sessions) -> prune_expired_oauth_sessions(sessions)
      _value -> %{}
    end
  end

  defp put_oauth_sessions(conn, sessions) when map_size(sessions) == 0,
    do: delete_session(conn, @clerk_oauth_sessions_key)

  defp put_oauth_sessions(conn, sessions),
    do: put_session(conn, @clerk_oauth_sessions_key, sessions)

  defp prune_expired_oauth_sessions(sessions) do
    cutoff = now() - @oauth_session_ttl_seconds

    Map.filter(sessions, fn {_state, entry} ->
      inserted_at = Map.get(entry, :inserted_at) || Map.get(entry, "inserted_at")
      is_integer(inserted_at) and inserted_at >= cutoff
    end)
  end

  defp keep_newest_oauth_sessions(sessions) do
    sessions
    |> Enum.sort_by(
      fn {_state, entry} ->
        Map.get(entry, :inserted_at) || Map.get(entry, "inserted_at") || 0
      end,
      :desc
    )
    |> Enum.take(@max_oauth_sessions)
    |> Map.new()
  end

  defp oauth_state(session_params) when is_map(session_params) do
    case Map.get(session_params, :state) || Map.get(session_params, "state") do
      state when is_binary(state) and state != "" -> state
      _state -> nil
    end
  end

  defp oauth_state(_session_params), do: nil

  defp now, do: System.system_time(:second)

  defp user_from_clerk(user) when is_map(user) do
    email = user["email"] || user[:email]
    id = user["sub"] || user[:sub] || user["user_id"] || user[:user_id]

    cond do
      !is_binary(email) or email == "" ->
        {:error, :missing_email}

      true ->
        {:ok, %{"id" => id || email, "email" => String.downcase(email), "provider" => "clerk"}}
    end
  end

  defp user_from_clerk(_user), do: {:error, :missing_email}

  defp authenticate(conn, %{"email" => email} = user, return_to) do
    redirect_to =
      if is_binary(return_to) and return_to != "/" and return_to != ~p"/" do
        return_to
      else
        case NamespaceStore.namespace_for_email(email) do
          namespace when is_binary(namespace) -> "/n/#{namespace}"
          nil -> ~p"/claim"
        end
      end

    conn
    |> configure_session(renew: true)
    |> put_session(:authenticated, true)
    |> put_session(:user, user)
    |> redirect(to: redirect_to)
  end

  defp auth_failed(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_resp_content_type("text/html")
    |> send_resp(401, auth_failed_html())
  end

  defp auth_failed_html do
    """
    <!doctype html>
    <html lang=\"en\">
      <head><title>Sign-in link expired</title></head>
      <body class=\"min-h-screen bg-zinc-950 text-zinc-100 flex items-center justify-center p-6\">
        <main class=\"max-w-md rounded-xl border border-zinc-800 bg-zinc-900 p-8 text-center shadow-xl\">
          <h1 class=\"text-2xl font-semibold\">Sign-in link expired</h1>
          <p class=\"mt-4 text-zinc-300\">This sign-in attempt is no longer valid. If you opened more than one sign-in tab, use the newest one or start again.</p>
          <a class=\"mt-6 inline-block rounded bg-white px-4 py-2 font-medium text-zinc-950\" href=\"/login\">Sign in again</a>
        </main>
      </body>
    </html>
    """
  end

  defp safe_return_to(path) when is_binary(path) do
    uri = URI.parse(path)

    if is_nil(uri.scheme) and is_nil(uri.host) and String.starts_with?(path, "/") and
         not String.starts_with?(path, "//") do
      path
    else
      ~p"/"
    end
  end

  defp safe_return_to(_path), do: ~p"/"

  defp clerk_oauth do
    Application.get_env(:unfinal, :clerk_oauth_client, UnfinalWeb.Auth.ClerkOAuth)
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
