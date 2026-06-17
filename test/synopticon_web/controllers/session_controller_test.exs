defmodule SynopticonWeb.SessionControllerTest do
  use SynopticonWeb.ConnCase

  setup do
    original_mode = Application.get_env(:synopticon, :login_mode)

    on_exit(fn ->
      if is_nil(original_mode) do
        Application.delete_env(:synopticon, :login_mode)
      else
        Application.put_env(:synopticon, :login_mode, original_mode)
      end
    end)
  end

  test "GET /login in dev fake mode signs in with exe-shaped identity", %{conn: conn} do
    Application.put_env(:synopticon, :login_mode, :dev_fake)

    conn = get(conn, ~p"/login")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :authenticated) == true

    assert get_session(conn, :exe_user) == %{
             "id" => "dev-user-1234",
             "email" => "dev@example.com"
           }
  end

  test "GET /login in dev fake mode redirects back to return_to", %{conn: conn} do
    Application.put_env(:synopticon, :login_mode, :dev_fake)

    conn = get(conn, ~p"/login?return_to=/notes")

    assert redirected_to(conn) == "/notes"
    assert get_session(conn, :authenticated) == true
  end

  test "GET /login rejects unsafe return_to", %{conn: conn} do
    Application.put_env(:synopticon, :login_mode, :dev_fake)

    conn = get(conn, ~p"/login?return_to=//evil.example")

    assert redirected_to(conn) == ~p"/"
  end

  test "GET /login with exe headers signs in and redirects back", %{conn: conn} do
    Application.put_env(:synopticon, :login_mode, :exe_headers)

    conn =
      conn
      |> put_req_header("x-exedev-userid", "usr1234")
      |> put_req_header("x-exedev-email", "user@example.com")
      |> get(~p"/login?return_to=/notes")

    assert redirected_to(conn) == "/notes"
    assert get_session(conn, :authenticated) == true
    assert get_session(conn, :exe_user) == %{"id" => "usr1234", "email" => "user@example.com"}
  end

  test "GET /login without exe headers redirects to exe login with encoded return path", %{
    conn: conn
  } do
    Application.put_env(:synopticon, :login_mode, :exe_headers)

    conn = get(conn, ~p"/login?return_to=/notes")

    assert redirected_to(conn) == "/__exe.dev/login?redirect=%2Flogin%3Freturn_to%3D%252Fnotes"
    refute get_session(conn, :authenticated)
  end
end
