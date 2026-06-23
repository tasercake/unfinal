defmodule UnfinalWeb.SessionController do
  use UnfinalWeb, :controller

  alias Unfinal.NamespaceStore

  @clerk_session_key :clerk_oauth_session_params
  @clerk_return_to_key :clerk_return_to
  @clerk_id_token_key :clerk_id_token

  def root(conn, _params), do: redirect(conn, to: ~p"/n")

  def login(conn, params) do
    return_to = safe_return_to(Map.get(params, "return_to"))
    start_clerk_oauth(conn, return_to)
  end

  def clerk_callback(conn, params), do: finish_clerk_oauth(conn, params)

  def logout(conn, _params) do
    id_token = get_session(conn, @clerk_id_token_key)
    conn = clear_session(conn)

    if is_binary(id_token) and id_token != "" do
      redirect(conn, external: clerk_end_session_url(id_token))
    else
      redirect(conn, to: ~p"/")
    end
  end

  defp start_clerk_oauth(conn, return_to) do
    with {:ok, config} <- clerk_config(conn),
         {:ok, %{url: url, session_params: session_params}} <- clerk_oauth().authorize_url(config) do
      conn
      |> put_session(@clerk_session_key, session_params)
      |> put_session(@clerk_return_to_key, return_to)
      |> redirect(external: url)
    else
      {:error, error} ->
        conn
        |> put_status(:service_unavailable)
        |> text("Clerk login unavailable: #{format_error(error)}")
    end
  end

  defp finish_clerk_oauth(conn, params) do
    session_params = get_session(conn, @clerk_session_key)
    return_to = get_session(conn, @clerk_return_to_key) |> safe_return_to()

    conn =
      conn
      |> delete_session(@clerk_session_key)
      |> delete_session(@clerk_return_to_key)

    with session_params when is_map(session_params) <- session_params,
         {:ok, config} <- clerk_config(conn),
         config = Keyword.put(config, :session_params, session_params),
         {:ok, %{user: user, token: %{"id_token" => id_token}}} <-
           clerk_oauth().callback(config, params),
         {:ok, app_user} <- user_from_clerk(user) do
      authenticate(conn, app_user, id_token, return_to)
    else
      nil ->
        auth_failed(conn, "missing login session")

      {:error, :missing_email} ->
        auth_failed(conn, "missing email")

      {:error, error} ->
        auth_failed(conn, format_error(error))
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

  defp clerk_end_session_url(id_token) do
    {:ok, frontend_api_url} = fetch_env("CLERK_FRONTEND_API_URL")

    frontend_api_url
    |> String.trim_trailing("/")
    |> URI.parse()
    |> URI.append_path("/oauth/end_session")
    |> URI.append_query(
      URI.encode_query(id_token_hint: id_token, post_logout_redirect_uri: url(~p"/"))
    )
    |> URI.to_string()
  end

  defp authenticate(conn, %{"email" => email} = user, id_token, return_to) do
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
    |> put_session(@clerk_id_token_key, id_token)
    |> redirect(to: redirect_to)
  end

  defp auth_failed(conn, reason) do
    conn
    |> put_status(:unauthorized)
    |> text("Clerk login failed: #{reason}")
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
