defmodule Unfinal.Repo.Migrations.CreateDocumentsAndNamespaceClaims do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE documents (
      path TEXT PRIMARY KEY,
      namespace TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      content TEXT NOT NULL DEFAULT '',
      revision INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    CREATE INDEX documents_namespace_updated_idx
    ON documents(namespace, updated_at DESC)
    """)

    execute("""
    CREATE TABLE namespace_claims (
      namespace TEXT PRIMARY KEY,
      email TEXT NOT NULL UNIQUE,
      claimed_at TEXT NOT NULL
    )
    """)
  end

  def down do
    execute("DROP TABLE namespace_claims")
    execute("DROP INDEX documents_namespace_updated_idx")
    execute("DROP TABLE documents")
  end
end
