defmodule Unfinal.Repo do
  use Ecto.Repo,
    otp_app: :unfinal,
    adapter: Ecto.Adapters.SQLite3
end
