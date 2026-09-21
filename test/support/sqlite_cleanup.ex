defmodule Unfinal.SQLiteCleanup do
  @moduledoc "Helpers for cleaning SQLite tables between tests."

  @doc "Delete all rows from document and namespace tables."
  def clear_all do
    Unfinal.Repo.query("DELETE FROM documents", [], timeout: 5_000)
    Unfinal.Repo.query("DELETE FROM document_redirects", [], timeout: 5_000)
    Unfinal.Repo.query("DELETE FROM namespace_claims", [], timeout: 5_000)
    :ok
  end
end
