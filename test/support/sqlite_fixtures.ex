defmodule Unfinal.SQLiteFixtures do
  @moduledoc "SQLite fixtures that preserve production database constraints."

  @spec claim_namespace(String.t()) :: :ok
  def claim_namespace(namespace) when is_binary(namespace) do
    claimed_at = DateTime.to_iso8601(DateTime.utc_now())

    {:ok, %{num_rows: 1}} =
      Unfinal.Repo.query(
        "INSERT INTO namespace_claims(namespace, user_id, email, claimed_at) VALUES (?1, ?2, ?3, ?4)",
        [namespace, "fixture-#{namespace}", "#{namespace}@example.test", claimed_at],
        timeout: 5_000
      )

    :ok
  end
end
