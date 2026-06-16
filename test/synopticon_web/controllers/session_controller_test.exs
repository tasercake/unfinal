defmodule SynopticonWeb.SessionControllerTest do
  use SynopticonWeb.ConnCase

  test "POST /login accepts hardcoded password", %{conn: conn} do
    conn = post(conn, ~p"/login", password: "synopticon")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :authenticated) == true
  end
end
