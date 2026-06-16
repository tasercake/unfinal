defmodule SynopticonWeb.PageControllerTest do
  use SynopticonWeb.ConnCase

  test "GET / renders the editor and login form", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "<textarea"
    assert response =~ "password"
    assert response =~ "log in"
  end
end
