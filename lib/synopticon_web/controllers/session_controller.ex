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

  def logout(conn, params) do
    return_to = safe_return_to(Map.get(params, "return_to"))

    conn
    |> clear_session()
    |> put_resp_content_type("text/html")
    |> html(logout_html(return_to))
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
    uri = URI.parse(path)

    if is_nil(uri.scheme) and is_nil(uri.host) and String.starts_with?(path, "/") and
         not String.starts_with?(path, "//") do
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

  defp logout_html(return_to) do
    encoded_return_to = return_to |> Jason.encode!() |> String.replace("</", "<\\/")

    """
    <!doctype html>
    <html lang=\"en\">
      <head>
        <meta charset=\"utf-8\">
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
        <title>Logging out · Synopticon</title>
      </head>
      <body class=\"min-h-dvh bg-stone-50 text-stone-950\">
        <main class=\"grid min-h-dvh place-items-center p-6 text-center\">
          <p>Logging out…</p>
        </main>
        <script>
          (() => {
            const fallback = "/";
            const returnTo = #{encoded_return_to};
            const safeReturnTo = value => value.startsWith("/") && !value.startsWith("//") ? value : fallback;
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 4000);
            fetch("/__exe.dev/logout", {method: "POST", credentials: "include", signal: controller.signal})
              .catch(() => {})
              .finally(() => {
                clearTimeout(timeout);
                window.location.replace(safeReturnTo(returnTo));
              });
          })();
        </script>
      </body>
    </html>
    """
  end
end
