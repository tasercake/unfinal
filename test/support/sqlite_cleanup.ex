defmodule Unfinal.SQLiteCleanup do
  @moduledoc "Helpers for cleaning SQLite tables between tests."

  @doc "Delete all rows from documents and namespace_claims tables."
  def clear_all do
    Unfinal.Repo.query("DELETE FROM documents", [], timeout: 5_000)
    Unfinal.Repo.query("DELETE FROM namespace_claims", [], timeout: 5_000)
    :ok
  end

  @doc "Delete all rows from documents table."
  def clear_documents do
    Unfinal.Repo.query("DELETE FROM documents", [], timeout: 5_000)
    :ok
  end

  @doc "Delete all rows from namespace_claims table."
  def clear_namespace_claims do
    Unfinal.Repo.query("DELETE FROM namespace_claims", [], timeout: 5_000)
    :ok
  end
end
