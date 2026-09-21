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
, "user_id" TEXT);
CREATE UNIQUE INDEX "namespace_claims_user_id_index" ON "namespace_claims" ("user_id");
CREATE TABLE document_redirects (
  source_path TEXT PRIMARY KEY,
  target_path TEXT NOT NULL,
  namespace TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX document_redirects_target_idx
ON document_redirects(target_path)
;
INSERT INTO schema_migrations VALUES(20260630000000,'0000-00-00T00:00:00');
INSERT INTO schema_migrations VALUES(20260701000000,'0000-00-00T00:00:00');
INSERT INTO schema_migrations VALUES(20260921000000,'0000-00-00T00:00:00');
