defmodule UnfinalWeb.SessionControllerTest do
  use UnfinalWeb.ConnCase

  alias Unfinal.NamespaceStore

  setup do
    original_mode = Application.get_env(:unfinal, :login_mode)
    previous_data_dir = System.get_env("UNFINAL_DATA_DIR")

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

      if previous_data_dir do
        System.put_env("UNFINAL_DATA_DIR", previous_data_dir)
      else
        System.delete_env("UNFINAL_DATA_DIR")
      end

      if is_nil(original_mode) do
        Application.delete_env(:unfinal, :login_mode)
      else
        Application.put_env(:unfinal, :login_mode, original_mode)
      end
    end)
  end

  test "GET /login in dev fake mode signs in with exe-shaped identity", %{conn: conn} do
    Application.put_env(:unfinal, :login_mode, :dev_fake)

    conn = get(conn, ~p"/login")

    assert redirected_to(conn) == ~p"/claim"
    assert get_session(conn, :authenticated) == true

    assert get_session(conn, :exe_user) == %{
             "id" => "dev-user-1234",
             "email" => "dev@example.com"
           }
  end

  test "GET /login in dev fake mode redirects unclaimed users to claim", %{conn: conn} do
    Application.put_env(:unfinal, :login_mode, :dev_fake)

    conn = get(conn, ~p"/login?return_to=/n/notes")

    assert redirected_to(conn) == "/claim"
    assert get_session(conn, :authenticated) == true
  end

  test "GET /login in dev fake mode redirects claimed users to their namespace", %{conn: conn} do
    Application.put_env(:unfinal, :login_mode, :dev_fake)
    :ok = NamespaceStore.claim("alpha", %{"email" => "dev@example.com"})

    conn = get(conn, ~p"/login?return_to=/n/notes")

    assert redirected_to(conn) == "/n/alpha"
    assert get_session(conn, :authenticated) == true
  end

  test "GET /login rejects unsafe return_to", %{conn: conn} do
    Application.put_env(:unfinal, :login_mode, :dev_fake)

    for unsafe <- ["//evil.example", "https://evil.example/path"] do
      conn = get(conn, ~p"/login?return_to=#{unsafe}")

      assert redirected_to(conn) == ~p"/claim"
    end
  end

  test "GET /login with exe headers signs in and redirects unclaimed users to claim", %{
    conn: conn
  } do
    Application.put_env(:unfinal, :login_mode, :exe_headers)

    conn =
      conn
      |> put_req_header("x-exedev-userid", "usr1234")
      |> put_req_header("x-exedev-email", "user@example.com")
      |> get(~p"/login?return_to=/n/notes")

    assert redirected_to(conn) == "/claim"
    assert get_session(conn, :authenticated) == true
    assert get_session(conn, :exe_user) == %{"id" => "usr1234", "email" => "user@example.com"}
  end

  test "GET /login with exe headers redirects claimed users to their namespace", %{conn: conn} do
    Application.put_env(:unfinal, :login_mode, :exe_headers)
    :ok = NamespaceStore.claim("beta", %{"email" => "user@example.com"})

    conn =
      conn
      |> put_req_header("x-exedev-userid", "usr1234")
      |> put_req_header("x-exedev-email", "user@example.com")
      |> get(~p"/login?return_to=/n/notes")

    assert redirected_to(conn) == "/n/beta"
    assert get_session(conn, :authenticated) == true
  end

  test "GET /login without exe headers redirects to exe login with encoded return path", %{
    conn: conn
  } do
    Application.put_env(:unfinal, :login_mode, :exe_headers)

    conn = get(conn, ~p"/login?return_to=/notes")

    assert redirected_to(conn) == "/__exe.dev/login?redirect=%2Flogin%3Freturn_to%3D%252Fnotes"
    refute get_session(conn, :authenticated)
  end

  test "GET /logout clears local session and renders exe.dev background logout page", %{
    conn: conn
  } do
    conn =
      conn
      |> Plug.Test.init_test_session(
        authenticated: true,
        exe_user: %{"id" => "usr1234", "email" => "user@example.com"}
      )
      |> get(~p"/logout?return_to=/notes")

    assert html_response(conn, 200) =~ "Logging out…"
    assert conn.resp_body =~ "fetch(\"/__exe.dev/logout\","
    assert conn.resp_body =~ ~s(method: "POST")
    assert conn.resp_body =~ ~s(credentials: "include")
    assert conn.resp_body =~ "AbortController"
    assert conn.resp_body =~ "4000"
    assert conn.resp_body =~ "const returnTo = \"/notes\";"
    assert conn.resp_body =~ "window.location.replace(safeReturnTo(returnTo));"
    refute get_session(conn, :authenticated)
    refute get_session(conn, :exe_user)
  end

  test "POST /logout remains supported and sanitizes unsafe return_to", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(
        authenticated: true,
        exe_user: %{"id" => "usr1234", "email" => "user@example.com"}
      )
      |> post(~p"/logout?return_to=https://evil.example/path")

    assert html_response(conn, 200) =~ "const returnTo = \"/\";"
    refute get_session(conn, :authenticated)
    refute get_session(conn, :exe_user)
  end
end
