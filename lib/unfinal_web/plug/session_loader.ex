defmodule UnfinalWeb.Plug.SessionLoader do
  @moduledoc """
  Thin wrapper around Plug.Session that resolves session options at call time
  via Application.get_env so encryption_salt and secure can vary per environment.

  In dev/test, encryption_salt is nil → signed cookies only (no encryption).
  In prod, encryption_salt comes from ENCRYPTION_SALT env var set in runtime.exs.
  """

  @behaviour Plug

  @impl true
  def init(_opts), do: :ok

  @impl true
  def call(conn, :ok) do
    Plug.Session.call(conn, session_config())
  end

  defp session_config do
    encryption_salt = Application.get_env(:unfinal, :encryption_salt)
    secure = Application.get_env(:unfinal, :secure_session_cookie, false)

    [
      store: :cookie,
      key: "_unfinal_key",
      signing_salt: "KOV7UCMl",
      same_site: "Lax"
    ]
    |> then(fn opts ->
      if encryption_salt, do: Keyword.put(opts, :encryption_salt, encryption_salt), else: opts
    end)
    |> Keyword.put(:secure, secure)
    |> Plug.Session.init()
  end
end
