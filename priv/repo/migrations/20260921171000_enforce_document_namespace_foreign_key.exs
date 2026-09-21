defmodule Unfinal.Repo.Migrations.EnforceDocumentNamespaceForeignKey do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE documents_with_namespace_fk (
      path TEXT PRIMARY KEY,
      namespace TEXT,
      relative_path TEXT NOT NULL,
      title TEXT NOT NULL DEFAULT '',
      content TEXT NOT NULL DEFAULT '',
      revision INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL,
      CONSTRAINT documents_root_namespace_check CHECK (
        (path = '/' AND namespace IS NULL AND relative_path = '/')
        OR
        (path <> '/' AND namespace IS NOT NULL)
      ),
      CONSTRAINT documents_namespace_fk
        FOREIGN KEY(namespace) REFERENCES namespace_claims(namespace) ON DELETE RESTRICT
    )
    """)

    execute("""
    INSERT INTO documents_with_namespace_fk (
      path,
      namespace,
      relative_path,
      title,
      content,
      revision,
      updated_at
    )
    SELECT
      path,
      CASE WHEN path = '/' THEN NULL ELSE namespace END,
      relative_path,
      title,
      content,
      revision,
      updated_at
    FROM documents
    """)

    execute("DROP TABLE documents")
    execute("ALTER TABLE documents_with_namespace_fk RENAME TO documents")

    # Covers both namespace page ordering and foreign-key child lookups.
    execute("""
    CREATE INDEX documents_namespace_updated_idx
    ON documents(namespace, updated_at DESC)
    """)
  end

  def down do
    execute("""
    CREATE TABLE documents_without_namespace_fk (
      path TEXT PRIMARY KEY,
      namespace TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      title TEXT NOT NULL DEFAULT '',
      content TEXT NOT NULL DEFAULT '',
      revision INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO documents_without_namespace_fk (
      path,
      namespace,
      relative_path,
      title,
      content,
      revision,
      updated_at
    )
    SELECT
      path,
      CASE WHEN path = '/' THEN '__root__' ELSE namespace END,
      relative_path,
      title,
      content,
      revision,
      updated_at
    FROM documents
    """)

    execute("DROP TABLE documents")
    execute("ALTER TABLE documents_without_namespace_fk RENAME TO documents")

    execute("""
    CREATE INDEX documents_namespace_updated_idx
    ON documents(namespace, updated_at DESC)
    """)
  end
end
