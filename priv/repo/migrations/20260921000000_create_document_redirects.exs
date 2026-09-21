defmodule Unfinal.Repo.Migrations.CreateDocumentRedirects do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE document_redirects (
      source_path TEXT PRIMARY KEY,
      target_path TEXT NOT NULL,
      namespace TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    """)

    execute("""
    CREATE INDEX document_redirects_target_idx
    ON document_redirects(target_path)
    """)
  end

  def down do
    execute("DROP INDEX document_redirects_target_idx")
    execute("DROP TABLE document_redirects")
  end
end
