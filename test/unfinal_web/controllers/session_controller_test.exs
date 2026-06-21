defmodule UnfinalWeb.SessionControllerTest do
  use UnfinalWeb.ConnCase

  alias Unfinal.NamespaceStore

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

      assert redirected_to(conn) == "https://clerk.example/oauth/authorize?state=fake"
      assert get_session(conn, :clerk_return_to) == ~p"/"
    end
  end

  test "GET /login redirects to Clerk and stores OAuth session", %{conn: conn} do
    put_clerk_config()

    conn = get(conn, ~p"/login?return_to=/n/notes")

    assert redirected_to(conn) == "https://clerk.example/oauth/authorize?state=fake"
    assert get_session(conn, :clerk_oauth_session_params) == %{state: "fake", nonce: "fake"}
    assert get_session(conn, :clerk_return_to) == "/n/notes"

    assert_received {:authorize_url, config}
    assert Keyword.fetch!(config, :base_url) == "https://clerk.example"

    assert Keyword.fetch!(config, :openid_configuration_uri) ==
             "/.well-known/oauth-authorization-server"

    assert Keyword.fetch!(config, :client_id) == "client_123"
    assert Keyword.fetch!(config, :client_secret) == "secret_123"
    assert Keyword.fetch!(config, :redirect_uri) == "http://localhost:4002/auth/clerk/callback"
    assert Keyword.fetch!(config, :code_verifier) == true
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
        clerk_oauth_session_params: %{state: "fake", nonce: "fake"},
        clerk_return_to: nil
      )
      |> get(~p"/auth/clerk/callback?code=ok&state=fake")

    assert redirected_to(conn) == ~p"/claim"
    assert get_session(conn, :authenticated) == true

    assert get_session(conn, :user) == %{
             "id" => "user_123",
             "email" => "user@example.com",
             "provider" => "clerk"
           }

    refute get_session(conn, :clerk_oauth_session_params)
    refute get_session(conn, :clerk_return_to)

    assert_received {:callback, config, %{"code" => "ok", "state" => "fake"}}
    assert Keyword.fetch!(config, :session_params) == %{state: "fake", nonce: "fake"}
  end

  test "GET /auth/clerk/callback redirects claimed users to their namespace", %{conn: conn} do
    put_clerk_config()
    :ok = NamespaceStore.claim("alpha", %{"email" => "user@example.com"})

    conn =
      conn
      |> Plug.Test.init_test_session(clerk_oauth_session_params: %{state: "fake"})
      |> get(~p"/auth/clerk/callback?code=ok")

    assert redirected_to(conn) == "/n/alpha"
    assert get_session(conn, :authenticated) == true
  end

  test "GET /auth/clerk/callback accepts Clerk email even when unverified flag is false", %{
    conn: conn
  } do
    put_clerk_config()

    conn =
      conn
      |> Plug.Test.init_test_session(clerk_oauth_session_params: %{state: "fake"})
      |> get(~p"/auth/clerk/callback?code=unverified")

    assert redirected_to(conn) == ~p"/claim"
    assert get_session(conn, :authenticated) == true
    assert get_session(conn, :user)["email"] == "user@example.com"
  end

  test "GET /auth/clerk/callback rejects missing OAuth session", %{conn: conn} do
    put_clerk_config()

    conn = get(conn, ~p"/auth/clerk/callback?code=ok")

    assert text_response(conn, 401) =~ "missing login session"
    refute get_session(conn, :authenticated)
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
