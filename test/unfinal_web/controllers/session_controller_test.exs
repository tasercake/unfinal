defmodule UnfinalWeb.SessionControllerTest do
  use UnfinalWeb.ConnCase

  alias Unfinal.NamespaceStore

  @oauth_sessions_key :clerk_oauth_sessions

  setup do
    original_client = Application.get_env(:unfinal, :clerk_oauth_client)

    original_env =
      stash_env([
        "CLERK_FRONTEND_API_URL",
        "CLERK_OAUTH_CLIENT_ID",
        "CLERK_OAUTH_CLIENT_SECRET",
        "CLERK_OAUTH_REDIRECT_URI",
        "CLERK_OAUTH_SCOPES",
        "UNFINAL_DATA_DIR"
      ])

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "unfinal-session-controller-#{System.unique_integer([:positive])}"
      )

    System.put_env("UNFINAL_DATA_DIR", data_dir)
    File.rm_rf!(data_dir)
    NamespaceStore.clear()

    on_exit(fn ->
      NamespaceStore.clear()
      File.rm_rf!(data_dir)
      restore_app_env(:clerk_oauth_client, original_client)
      restore_env(original_env)
    end)
  end

  test "GET /login rejects unsafe return_to", %{conn: conn} do
    put_clerk_config()

    for unsafe <- ["//evil.example", "https://evil.example/path"] do
      conn = get(conn, ~p"/login?return_to=#{unsafe}")
      sessions = get_session(conn, @oauth_sessions_key)
      {_state, entry} = only_session(sessions)

      assert redirected_to(conn) =~ "https://clerk.example/oauth/authorize?state=fake-"
      assert entry.return_to == ~p"/"
    end
  end

  test "GET /login redirects to Clerk and stores OAuth session by state with return_to", %{
    conn: conn
  } do
    put_clerk_config()

    conn = get(conn, ~p"/login?return_to=/n/notes")

    assert redirected_to(conn) =~ "https://clerk.example/oauth/authorize?state=fake-"

    sessions = get_session(conn, @oauth_sessions_key)
    {state, entry} = only_session(sessions)

    assert entry.session_params == %{state: state, nonce: "fake"}
    assert entry.return_to == "/n/notes"
    assert is_integer(entry.inserted_at)
    refute get_session(conn, :clerk_oauth_session_params)
    refute get_session(conn, :clerk_return_to)

    assert_received {:authorize_url, config}
    assert Keyword.fetch!(config, :base_url) == "https://clerk.example"

    assert Keyword.fetch!(config, :openid_configuration_uri) ==
             "/.well-known/oauth-authorization-server"

    assert Keyword.fetch!(config, :client_id) == "client_123"
    assert Keyword.fetch!(config, :client_secret) == "secret_123"
    assert Keyword.fetch!(config, :redirect_uri) == "http://localhost:4002/auth/clerk/callback"
    assert Keyword.fetch!(config, :code_verifier) == true
  end

  test "two login starts preserve both states and older callback still authenticates", %{
    conn: conn
  } do
    put_clerk_config()

    first_conn = get(conn, ~p"/login?return_to=/n/first")
    {first_state, _first_entry} = only_session(get_session(first_conn, @oauth_sessions_key))

    second_conn = get(first_conn, ~p"/login?return_to=/n/second")
    sessions = get_session(second_conn, @oauth_sessions_key)
    assert map_size(sessions) == 2
    assert Map.has_key?(sessions, first_state)
    second_state = sessions |> Map.keys() |> Enum.find(&(&1 != first_state))

    callback_conn = get(second_conn, ~p"/auth/clerk/callback?code=ok&state=#{first_state}")

    assert redirected_to(callback_conn) == "/n/first"
    assert get_session(callback_conn, :authenticated) == true
    assert get_session(callback_conn, @oauth_sessions_key) |> Map.has_key?(second_state)
  end

  test "callback removes only used state and leaves remaining state", %{conn: conn} do
    put_clerk_config()

    conn = get(conn, ~p"/login?return_to=/n/first")
    {first_state, _entry} = only_session(get_session(conn, @oauth_sessions_key))
    conn = get(conn, ~p"/login?return_to=/n/second")

    conn = get(conn, ~p"/auth/clerk/callback?code=ok&state=#{first_state}")

    sessions = get_session(conn, @oauth_sessions_key)
    refute Map.has_key?(sessions, first_state)
    assert map_size(sessions) == 1
  end

  test "GET /login fails clearly when Clerk env missing", %{conn: conn} do
    Application.put_env(:unfinal, :clerk_oauth_client, UnfinalWeb.FakeClerkOAuth)
    delete_clerk_env()

    conn = get(conn, ~p"/login")

    assert text_response(conn, 503) =~ "missing CLERK_FRONTEND_API_URL"
  end

  test "GET /auth/clerk/callback signs in Clerk email and redirects unclaimed users to claim", %{
    conn: conn
  } do
    put_clerk_config()

    conn =
      conn
      |> Plug.Test.init_test_session(
        clerk_oauth_sessions: %{
          "fake" => %{
            session_params: %{state: "fake", nonce: "fake"},
            return_to: nil,
            inserted_at: now()
          }
        }
      )
      |> get(~p"/auth/clerk/callback?code=ok&state=fake")

    assert redirected_to(conn) == ~p"/claim"
    assert get_session(conn, :authenticated) == true

    assert get_session(conn, :user) == %{
             "id" => "user_123",
             "email" => "user@example.com",
             "provider" => "clerk"
           }

    refute get_session(conn, @oauth_sessions_key)

    assert_received {:callback, config, %{"code" => "ok", "state" => "fake"}}
    assert Keyword.fetch!(config, :session_params) == %{state: "fake", nonce: "fake"}
  end

  test "GET /auth/clerk/callback redirects claimed users to their namespace", %{conn: conn} do
    put_clerk_config()
    :ok = NamespaceStore.claim("alpha", %{"email" => "user@example.com"})

    conn =
      conn
      |> Plug.Test.init_test_session(
        clerk_oauth_sessions: %{
          "fake" => %{session_params: %{state: "fake"}, return_to: nil, inserted_at: now()}
        }
      )
      |> get(~p"/auth/clerk/callback?code=ok&state=fake")

    assert redirected_to(conn) == "/n/alpha"
    assert get_session(conn, :authenticated) == true
  end

  test "GET /auth/clerk/callback accepts Clerk email even when unverified flag is false", %{
    conn: conn
  } do
    put_clerk_config()

    conn =
      conn
      |> Plug.Test.init_test_session(
        clerk_oauth_sessions: %{
          "fake" => %{session_params: %{state: "fake"}, return_to: nil, inserted_at: now()}
        }
      )
      |> get(~p"/auth/clerk/callback?code=unverified&state=fake")

    assert redirected_to(conn) == ~p"/claim"
    assert get_session(conn, :authenticated) == true
    assert get_session(conn, :user)["email"] == "user@example.com"
  end

  test "GET /auth/clerk/callback rejects missing or unknown state with friendly page", %{
    conn: conn
  } do
    put_clerk_config()

    for path <- [~p"/auth/clerk/callback?code=ok", ~p"/auth/clerk/callback?code=ok&state=unknown"] do
      conn = get(conn, path)
      body = html_response(conn, 401)

      assert body =~ "Sign-in link expired"
      assert body =~ "This sign-in attempt is no longer valid"
      assert body =~ "Sign in again"
      refute body =~ "%Assent"
      refute body =~ "CallbackCSRFError"
      refute body =~ "%{"
      refute get_session(conn, :authenticated)
    end
  end

  test "Assent callback CSRF error returns friendly page without raw leak", %{conn: conn} do
    put_clerk_config()

    conn =
      conn
      |> Plug.Test.init_test_session(
        clerk_oauth_sessions: %{
          "fake" => %{session_params: %{state: "fake"}, return_to: nil, inserted_at: now()}
        }
      )
      |> get(~p"/auth/clerk/callback?code=csrf_error&state=fake")

    body = html_response(conn, 401)
    assert body =~ "Sign-in link expired"
    refute body =~ "%Assent"
    refute body =~ "CallbackCSRFError"
  end

  test "more than five entries prunes oldest on login", %{conn: conn} do
    put_clerk_config()
    base_time = now()

    old_sessions =
      Map.new(1..5, fn i ->
        {"old-#{i}",
         %{
           session_params: %{state: "old-#{i}"},
           return_to: "/",
           inserted_at: base_time - (6 - i)
         }}
      end)

    conn =
      conn
      |> Plug.Test.init_test_session(clerk_oauth_sessions: old_sessions)
      |> get(~p"/login")

    sessions = get_session(conn, @oauth_sessions_key)

    assert map_size(sessions) == 5
    refute Map.has_key?(sessions, "old-1")
    assert Map.has_key?(sessions, "old-2")
    assert Map.has_key?(sessions, "fake-1")
  end

  test "entries older than 24 hours are expired and rejected", %{conn: conn} do
    put_clerk_config()

    conn =
      conn
      |> Plug.Test.init_test_session(
        clerk_oauth_sessions: %{
          "old" => %{
            session_params: %{state: "old"},
            return_to: "/n/old",
            inserted_at: now() - 24 * 60 * 60 - 1
          },
          "fresh" => %{
            session_params: %{state: "fresh"},
            return_to: "/n/fresh",
            inserted_at: now()
          }
        }
      )
      |> get(~p"/auth/clerk/callback?code=ok&state=old")

    body = html_response(conn, 401)
    assert body =~ "Sign-in link expired"
    sessions = get_session(conn, @oauth_sessions_key)
    refute Map.has_key?(sessions, "old")
    assert Map.has_key?(sessions, "fresh")
  end

  test "GET /logout clears local session and redirects safely", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(
        authenticated: true,
        user: %{"id" => "usr1234", "email" => "user@example.com"}
      )
      |> get(~p"/logout?return_to=/notes")

    assert redirected_to(conn) == "/notes"
    refute get_session(conn, :authenticated)
    refute get_session(conn, :user)
  end

  test "POST /logout remains supported and sanitizes unsafe return_to", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(
        authenticated: true,
        user: %{"id" => "usr1234", "email" => "user@example.com"}
      )
      |> post(~p"/logout?return_to=https://evil.example/path")

    assert redirected_to(conn) == "/"
    refute get_session(conn, :authenticated)
    refute get_session(conn, :user)
  end

  defp only_session(sessions) do
    assert is_map(sessions)
    assert map_size(sessions) == 1
    hd(Map.to_list(sessions))
  end

  defp now, do: System.system_time(:second)

  defp put_clerk_config do
    Application.put_env(:unfinal, :clerk_oauth_client, UnfinalWeb.FakeClerkOAuth)
    System.put_env("CLERK_FRONTEND_API_URL", "https://clerk.example/")
    System.put_env("CLERK_OAUTH_CLIENT_ID", "client_123")
    System.put_env("CLERK_OAUTH_CLIENT_SECRET", "secret_123")
    System.put_env("CLERK_OAUTH_REDIRECT_URI", "http://localhost:4002/auth/clerk/callback")
  end

  defp delete_clerk_env do
    for name <- [
          "CLERK_FRONTEND_API_URL",
          "CLERK_OAUTH_CLIENT_ID",
          "CLERK_OAUTH_CLIENT_SECRET",
          "CLERK_OAUTH_REDIRECT_URI",
          "CLERK_OAUTH_SCOPES"
        ],
        do: System.delete_env(name)
  end

  defp stash_env(names), do: Map.new(names, &{&1, System.get_env(&1)})

  defp restore_env(values) do
    Enum.each(values, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:unfinal, key)
  defp restore_app_env(key, value), do: Application.put_env(:unfinal, key, value)
end
