defmodule SynopticonWeb.SessionController do
  use SynopticonWeb, :controller

  @password "synopticon"

  def create(conn, %{"password" => @password}) do
    conn
    |> put_session(:authenticated, true)
    |> delete_session(:password_error)
    |> redirect(to: ~p"/")
  end

  def create(conn, _params) do
    conn
    |> put_session(:password_error, true)
    |> redirect(to: ~p"/")
  end
end
