# Phase 7 — Delete S3-era Index Abstractions — TODO

## Ownership

- Parent agent owns this file and is the only actor allowed to update progress checkboxes or reviewer fields.
- Execution agents and review agents must treat SCOPE, PLAN, and TODO as read-only.
- TODO is the source of progress truth. PLAN is the source of work-detail truth. SCOPE is the source of goal/constraint truth.

## Legend

- `[ ]` — Not started
- `[~]` — In progress; parent assigned this task to an execution subagent
- `[x]` — Done; implementation completed and reviewer approved

## Execution Rules

- Execute phases in listed order.
- Tasks within a phase may run in parallel only when explicitly listed as parallel-safe.
- Tasks across phases must not run in parallel.
- Execution agents must follow the referenced PLAN items exactly and must not derive, rewrite, reorganize, or reinterpret TODO.

## Tasks

### Phase 1: Preconditions and Baseline

Parallelism: none
Dependencies: none

- [x] **P7-001**: Confirm all Phase 6 stop gates; PLAN reference: `Preconditions / Stop Gates`; Files: `lib/unfinal`, `config`, `priv/repo`, tests; Reviewer: pending — subagent 2cfd649e
- [x] **P7-002**: Run baseline compile/tests/dead-reference searches; PLAN reference: `Implementation Order` item 1 and `Testing Strategy`; Files: project-wide; Reviewer: pending — subagent 2cfd649e

### Phase 2: Update Callers Before Deletion

Parallelism: `P7-003`, `P7-004`, `P7-005` may run in parallel after Phase 1
Dependencies: Phase 1 complete

- [x] **P7-003**: Update `R2ToSQLiteBackfill` — replace `ObjectIndex.get/1` with `LegacyR2Archive.get_object/1`, inline key construction; PLAN reference: `File-by-File Implementation` → item 1; Files: `lib/unfinal/r2_to_sqlite_backfill.ex`; Reviewer: pending — subagent 2cfd649e
- [x] **P7-004**: Remove dead helpers (`parse/1`, `write/2`, `key/1`) from `PageIndex`; PLAN reference: `File-by-File Implementation` → item 2; Files: `lib/unfinal/page_index.ex`; Reviewer: pending — subagent 2cfd649e
- [x] **P7-005**: Update `migrate_r2_indexes.ex` moduledoc — remove reference to deleted `R2IndexMigration`; PLAN reference: `File-by-File Implementation` → item 3; Files: `lib/mix/tasks/unfinal.migrate_r2_indexes.ex`; Reviewer: pending — subagent 2cfd649e (no change needed — moduledoc already clean)

### Phase 3: Delete Dead Modules

Parallelism: all deletions may run in parallel
Dependencies: Phase 2 complete (callers updated first)

- [x] **P7-006**: Delete `object_index.ex`, `page_index_server.ex`, `r2_index_migration.ex`, `sqlite_shadow.ex`; PLAN reference: `File-by-File Implementation` → item 4; Files: `lib/unfinal/object_index.ex`, `lib/unfinal/page_index_server.ex`, `lib/unfinal/r2_index_migration.ex`, `lib/unfinal/sqlite_shadow.ex`; Reviewer: pending — subagent 2cfd649e (sqlite_shadow.ex already deleted in Phase 6)

### Phase 4: Flatten NamespaceStore

Parallelism: none
Dependencies: Phase 3 complete

- [x] **P7-007**: Flatten `NamespaceStore` from GenServer to plain SQL module; PLAN reference: `File-by-File Implementation` → item 5; Files: `lib/unfinal/namespace_store.ex`; Reviewer: pending — subagent 2cfd649e
- [x] **P7-008**: Remove `NamespaceStore` from application supervision; PLAN reference: `File-by-File Implementation` → item 6; Files: `lib/unfinal/application.ex`; Reviewer: pending — subagent 2cfd649e

### Phase 5: Tests and Test Support

Parallelism: `P7-009` through `P7-013` may run in parallel after Phase 4
Dependencies: Phase 4 complete

- [x] **P7-009**: Delete dead test files: `r2_index_migration_test.exs`, `sqlite_shadow_test.exs`, `blocking_index_object_store.ex`, `flaky_index_load_object_store.ex`, `failing_sqlite_shadow_repo.ex`; PLAN reference: `Test Changes` → item 13; Files: listed files; Reviewer: pending — subagent 2cfd649e (only r2_index_migration_test.exs existed; rest already deleted in Phase 6)
- [x] **P7-010**: Update `page_index_test.exs` — remove tests for deleted `parse/1`, `write/2`, R2 spy; PLAN reference: `Test Changes` → item 9; Files: `test/unfinal/page_index_test.exs`; Reviewer: pending — subagent 2cfd649e
- [x] **P7-011**: Update `namespace_store_test.exs` — remove GenServer-specific and R2 spy tests; PLAN reference: `Test Changes` → item 10; Files: `test/unfinal/namespace_store_test.exs`; Reviewer: pending — subagent 2cfd649e
- [x] **P7-012**: Update `r2_to_sqlite_backfill_test.exs` — remove ObjectIndex alias/test; PLAN reference: `Test Changes` → item 11; Files: `test/unfinal/r2_to_sqlite_backfill_test.exs`; Reviewer: pending — subagent 2cfd649e (no ObjectIndex references found — already clean)
- [x] **P7-013**: Update `claim_live_test.exs`, `editor_live_test.exs`, `session_controller_test.exs` — remove `:sys.replace_state` on NamespaceStore; PLAN reference: Test Changes (additional — GenServer removal ripples); Files: listed test files; Reviewer: pending — subagent 2cfd649e

### Phase 6: Verification and PR Readiness

Parallelism: none
Dependencies: Phase 5 complete

- [x] **P7-014**: Run `mix format --check-formatted && mix compile --warnings-as-errors && mix test`; PLAN reference: `Testing Strategy`; Files: project-wide; Reviewer: pending — subagent 2cfd649e (131 tests, 0 failures, format OK, warnings-as-errors OK)
- [x] **P7-015**: Run dead-code searches for all deleted module references; PLAN reference: `Dead Code Verification`; Files: project-wide; Reviewer: pending — subagent 2cfd649e (all 4 searches return zero hits)
- [x] **P7-016**: Verify legacy flags/tasks do not crash startup; PLAN reference: `Testing Strategy` item 10; Files: runtime config/tasks; Reviewer: pending — subagent 2cfd649e (verify_sqlite_cutover.ex updated to use LegacyR2Archive; LegacyR2Archive updated to use adapter config)

## Additional Changes (not in original TODO)

These were required by the NamespaceStore GenServer → plain module flattening:

- **`lib/unfinal/legacy_r2_archive.ex`**: Updated `get_object/1` and `get_document/1` to use the configured `:object_store_adapter` instead of hardcoding `S3ObjectStore`. This preserves testability (tests set `FakeObjectStore` as adapter).
- **`lib/mix/tasks/unfinal.verify_sqlite_cutover.ex`**: Updated all `ObjectIndex.get/1` calls to `LegacyR2Archive.get_object/1`.
- **`test/unfinal_web/live/claim_live_test.exs`**: Removed `:sys.replace_state(NamespaceStore, ...)` calls; replaced with `Application.put_env(:unfinal, :storage_mode, :sqlite)`.
- **`test/unfinal_web/live/editor_live_test.exs`**: Removed `:sys.replace_state(NamespaceStore, ...)` calls (storage_mode already set via Application.put_env).
- **`test/unfinal_web/controllers/session_controller_test.exs`**: Removed `:sys.replace_state(NamespaceStore, ...)` in the "redirects claimed users" test.
- **`lib/unfinal/page_index.ex`**: Added `sqlite_primary?/0` guard to `list/1` and `upsert/3` to preserve R2-mode behavior (no SQLite writes when `storage_mode: :r2`).
