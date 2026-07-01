defmodule Mix.Tasks.Unfinal.MigrateR2ToSqlite do
  @moduledoc """
  Backfills SQLite from R2 indexes while R2 remains primary.

  Reads namespace claims and page indexes from R2/object storage,
  reconstructs full document paths, fetches documents through the
  current ContentStore adapter, and conditionally upserts into SQLite
  without overwriting rows newer than the R2 source data.

  Modes:

      mix unfinal.migrate_r2_to_sqlite --dry-run
      mix unfinal.migrate_r2_to_sqlite --commit
      mix unfinal.migrate_r2_to_sqlite --commit --report /path/to/report.json

  Passing both `--dry-run` and `--commit` is invalid. Passing neither
  defaults to dry-run mode.

  Options:

      --dry-run    Read R2 indexes, fetch documents, compute expected
                   counts, but write no SQLite rows.
      --commit     Perform reads and write guarded namespace claim and
                   document upserts into SQLite.
      --report PATH  Write a JSON report file with counts and details.
  """

  use Mix.Task

  @shortdoc "Backfills SQLite from R2 indexes while R2 remains primary"

  @impl true
  def run(args) do
    {opts, _remaining, invalid} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, commit: :boolean, report: :string]
      )

    if invalid != [] do
      Mix.raise("invalid option(s): #{inspect(invalid)}")
    end

    dry_run? = Keyword.get(opts, :dry_run, false)
    commit? = Keyword.get(opts, :commit, false)

    mode =
      cond do
        dry_run? and commit? ->
          Mix.raise("cannot pass both --dry-run and --commit")

        commit? ->
          :commit

        true ->
          # Default to dry-run when neither is specified
          if not dry_run? do
            Mix.shell().info("mode: dry-run (pass --commit to write)")
          end

          :dry_run
      end

    report_path = Keyword.get(opts, :report)

    # Start the application so runtime config, R2 adapter, and Repo are available
    Mix.Task.run("app.start")

    backfill_opts = [
      mode: mode,
      report_path: report_path
    ]

    case Unfinal.R2ToSQLiteBackfill.run(backfill_opts) do
      {:ok, report} ->
        log_report(report)

      {:error, reason} ->
        Mix.raise("R2 to SQLite backfill failed: #{inspect(reason)}")
    end
  end

  defp log_report(report) do
    mode = Map.get(report, "mode", "unknown")
    ns_valid = Map.get(report, "namespace_rows_valid", 0)
    ns_inserted = Map.get(report, "namespace_claims_inserted", 0)
    ns_existing = Map.get(report, "namespace_claims_existing", 0)
    ns_conflicts = Map.get(report, "namespace_claim_conflicts", [])
    doc_expected = Map.get(report, "documents_expected", 0)
    doc_fetched = Map.get(report, "documents_fetched", 0)
    doc_inserted = Map.get(report, "documents_inserted", 0)
    doc_updated = Map.get(report, "documents_updated", 0)
    doc_skipped = Map.get(report, "documents_skipped_newer", [])
    doc_missing = Map.get(report, "missing_indexed_documents", [])
    dupes = Map.get(report, "page_index_entries_duplicate", 0)
    invalid_ns = Map.get(report, "namespace_rows_invalid", [])
    invalid_pages = Map.get(report, "page_index_entries_invalid", [])

    Mix.shell().info(
      "R2 to SQLite backfill complete (#{mode})" <>
        "\n  namespaces: #{ns_valid} valid, #{ns_inserted} inserted, #{ns_existing} existing, #{length(ns_conflicts)} conflict(s)" <>
        "\n  documents: #{doc_expected} expected, #{doc_fetched} fetched, #{doc_inserted} inserted, #{doc_updated} updated, #{length(doc_skipped)} skipped (newer in SQLite)" <>
        "\n  duplicates collapsed: #{dupes}" <>
        "\n  missing indexed documents: #{length(doc_missing)}"
    )

    if ns_conflicts != [] do
      Mix.shell().info("  namespace claim conflicts:")

      Enum.each(ns_conflicts, fn conflict ->
        Mix.shell().info("    #{inspect(conflict)}")
      end)
    end

    if doc_missing != [] do
      Mix.shell().info("  missing indexed documents:")

      Enum.each(doc_missing, fn entry ->
        Mix.shell().info("    #{entry.full_path} (key: #{entry.expected_key})")
      end)
    end

    if invalid_ns != [] do
      Mix.shell().info("  invalid namespace lines: #{length(invalid_ns)}")
    end

    if invalid_pages != [] do
      Mix.shell().info("  invalid page index entries: #{length(invalid_pages)}")
    end
  end
end
