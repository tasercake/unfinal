# Phase 4 — R2 to SQLite Backfill, R2 Still Primary

## Summary

Phase 4 adds an idempotent pre-deploy Mix task (`mix unfinal.migrate_r2_to_sqlite`) that backfills all recoverable R2 index data into SQLite while the running application remains R2-primary. The task reads `indexes/namespaces.txt` and each `indexes/namespaces/<namespace>.ndjson` to reconstruct full document paths, fetches the corresponding hashed document objects from R2, and conditionally upserts them into SQLite. Namespace claims are inserted only when no conflict exists; documents are updated only when the existing SQLite row is not newer than the R2 source.

The task supports `--dry-run` (read-only audit) and `--commit` (write mode) flags, plus `--report PATH` for machine-readable JSON output. It runs inside `deploy-exe-dev.sh` on the exe.dev host before service restart, so no R2 or SQLite secrets are exposed to GitHub Actions.

## Deployment Report Review Expectations

After each deploy, review the JSON report file archived under `${UNFINAL_DATA_DIR}/migration-reports/`:

- **`namespace_rows_valid`** should match the expected count of valid namespace entries in R2.
- **`documents_expected`** should equal unique reconstructed page index entries across all namespaces.
- **`documents_fetched` + length of `missing_indexed_documents`** should equal `documents_expected`.
- **`documents_inserted` + `documents_updated` + length of `documents_skipped_newer`** should equal `documents_fetched` in commit mode.
- **`namespace_claims_inserted`** reflects new claims added; `namespace_claims_existing` reflects claims that already existed.
- **`missing_indexed_documents`** lists R2-indexed paths whose hashed document blobs could not be fetched (missing objects, not fatal errors).
- **`fatal_errors`** should be empty; if non-empty, the task exited non-zero and GitHub Actions failed the deploy.
- Orphan hashed blobs (`documents/*` not referenced by any index) are intentionally not listed or processed.

## Rollback Expectations

- **If deploy fails during backfill**: GitHub Actions fails before service restart. The previously running R2-primary app remains the source of truth. Fix the R2/SQLite/env issue or revert the Phase 4 PR and redeploy.
- **If deploy succeeds but reports unexpected data**: Do not delete SQLite rows and do not mutate R2. Keep R2 primary, inspect the archived report, and address issues with a separate task if needed. The backfill is idempotent and can be rerun safely.
- **If the Phase 4 PR is rolled back after successful deployment**: Leave SQLite data in place. It is dormant because runtime reads and writes still use R2 primary. A later corrected Phase 4 can rerun safely because writes are guarded against newer SQLite rows.

## Key Files Added or Modified

### Added by Phase 4
- `lib/unfinal/r2_to_sqlite_backfill.ex` — Core backfill module with R2 index parsing, path reconstruction, document fetch, guarded SQLite upserts, and report generation.
- `lib/mix/tasks/unfinal.migrate_r2_to_sqlite.ex` — Mix task CLI wrapper with `--dry-run`, `--commit`, and `--report` options.
- `test/unfinal/r2_to_sqlite_backfill_test.exs` — Unit and integration tests for the core backfill module.
- `test/mix/tasks/migrate_r2_to_sqlite_test.exs` — Mix task CLI and behavior tests.

### Modified by Phase 4
- `deploy-exe-dev.sh` — Added pre-deploy backfill invocation that sources env, runs `mix unfinal.migrate_r2_to_sqlite --commit --report`, and archives the JSON report before service restart.

### NOT modified (R2-primary runtime preserved)
- `lib/unfinal/document_server.ex` — Reads/writes remain R2 via ContentStore adapter.
- `lib/unfinal/documents.ex` — Delegates to DocumentServer/ContentStore, unchanged.
- `lib/unfinal/namespace_store.ex` — Reads/writes remain R2 via ObjectIndex.
- `lib/unfinal/page_index.ex` — Reads/writes remain R2 via ObjectIndex.
- `lib/unfinal/page_index_server.ex` — Reads/writes remain R2 via ObjectIndex.
- `lib/unfinal/content_store.ex` — Unchanged adapter boundary.
- `lib/unfinal/s3_object_store.ex` — Unchanged R2 adapter implementation.
- `lib/unfinal/repo.ex` — Unchanged SQLite Ecto repo.
- `lib/unfinal/sqlite_shadow.ex` — Unchanged Phase 3 shadow dual-write module.
- `lib/unfinal/application.ex` — No new supervisors or runtime changes.
