CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" INTEGER PRIMARY KEY, "inserted_at" TEXT);
CREATE TABLE documents (
  path TEXT PRIMARY KEY,
  namespace TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  revision INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
CREATE INDEX documents_namespace_updated_idx
ON documents(namespace, updated_at DESC)
;
CREATE TABLE namespace_claims (
  namespace TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  claimed_at TEXT NOT NULL
);
INSERT INTO schema_migrations VALUES(20260630000000,'0000-00-00T00:00:00');
