defmodule UnfinalWeb.PageControllerTest do
  use UnfinalWeb.ConnCase

  test "GET / redirects to /n", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/n"
  end
end
