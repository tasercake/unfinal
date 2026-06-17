defmodule SynopticonWeb.SessionController do
  use SynopticonWeb, :controller

  @dev_fake_user %{"id" => "dev-user-1234", "email" => "dev@example.com"}

  def login(conn, params) do
    return_to = safe_return_to(Map.get(params, "return_to"))

    case Application.fetch_env!(:synopticon, :login_mode) do
      :dev_fake ->
        authenticate(conn, @dev_fake_user, return_to)

      :exe_headers ->
        case exe_user_from_headers(conn) do
          {:ok, user} -> authenticate(conn, user, return_to)
          :error -> redirect(conn, to: exe_login_path(return_to))
        end
    end
  end

  defp exe_user_from_headers(conn) do
    with [id] when id != "" <- get_req_header(conn, "x-exedev-userid"),
         [email] when email != "" <- get_req_header(conn, "x-exedev-email") do
      {:ok, %{"id" => id, "email" => email}}
    else
      _ -> :error
    end
  end

  defp authenticate(conn, user, return_to) do
    conn
    |> put_session(:authenticated, true)
    |> put_session(:exe_user, user)
    |> redirect(to: return_to)
  end

  defp safe_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    else
      ~p"/"
    end
  end

  defp safe_return_to(_path), do: ~p"/"

  defp exe_login_path(return_to) do
    redirect_path = ~p"/login?return_to=#{return_to}"
    "/__exe.dev/login?redirect=#{URI.encode_www_form(redirect_path)}"
  end
end
