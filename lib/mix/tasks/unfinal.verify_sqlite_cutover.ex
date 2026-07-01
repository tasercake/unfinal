defmodule Mix.Tasks.Unfinal.VerifySqliteCutover do
  @shortdoc "Verify SQLite cutover completeness (requires --allow-r2-archive-read)"
  @moduledoc """
  Deploy verification task that checks SQLite has all R2-indexed data.

  Requires `--allow-r2-archive-read` to access the R2 read-only archive.

  Run during deploy (after R2-to-SQLite catch-up, before app restart):

      mix unfinal.verify_sqlite_cutover --allow-r2-archive-read

  Fails (non-zero exit) if any R2 namespace claim or indexed document is missing.

  Note: Phase 6 assumes cutover is already verified; this task is no longer
  needed as a normal pre-deploy step.
  """

  use Mix.Task
  require Logger

  alias Unfinal.R2Index
  alias Unfinal.ObjectIndex
  alias Unfinal.SqliteDocuments
  alias Unfinal.Repo

  @impl true
  def run(args) do
    {opts, _remaining, invalid} =
      OptionParser.parse(args, strict: [allow_r2_archive_read: :boolean])

    if invalid != [] do
      Mix.raise("invalid option(s): #{inspect(invalid)}")
    end

    unless Keyword.get(opts, :allow_r2_archive_read, false) do
      Mix.raise(
        "R2 archive reads are disabled. R2 is read-only archive; normal app traffic uses SQLite.\n" <>
          "Pass --allow-r2-archive-read to explicitly enable R2 archive access for this task."
      )
    end

    # Set env flag so LegacyR2Archive.allowed?/0 returns true
    System.put_env("UNFINAL_ALLOW_R2_ARCHIVE_READ", "true")

    # Start the app/Repo
    Mix.Task.run("app.start", ["--no-start"])
    {:ok, _} = Application.ensure_all_started(:unfinal)

    IO.puts("\n=== SQLite Cutover Verification ===\n")

    with {:ok, r2_ns_count} <- verify_namespace_claims(),
         {:ok, r2_doc_count} <- verify_indexed_documents() do
      sqlite_doc_count = SqliteDocuments.count_documents()

      IO.puts("\n=== Summary ===")
      IO.puts("R2 namespace claims: #{r2_ns_count}")
      IO.puts("R2 indexed documents: #{r2_doc_count}")
      IO.puts("SQLite total documents: #{sqlite_doc_count}")
      IO.puts("\n✅ SQLite cutover verification passed\n")
    else
      {:error, reason} ->
        IO.puts("\n❌ SQLite cutover verification FAILED: #{inspect(reason)}\n")
        Mix.raise("SQLite cutover verification failed: #{inspect(reason)}")
    end
  end

  defp verify_namespace_claims do
    case ObjectIndex.get(R2Index.namespace_index_key()) do
      {:ok, content} ->
        r2_claims = R2Index.parse_namespace_tsv(content)
        IO.puts("R2 namespace claims: #{length(r2_claims)}")

        Enum.each(r2_claims, fn {namespace, email} ->
          sql = "SELECT email FROM namespace_claims WHERE namespace = ?1 LIMIT 1"

          case Repo.query(sql, [namespace], timeout: 1_000) do
            {:ok, %{rows: [[^email]]}} ->
              :ok

            {:ok, %{rows: []}} ->
              Mix.raise("Missing namespace claim in SQLite: #{namespace} (#{email})")

            {:ok, %{rows: [[other_email]]}} ->
              Mix.raise(
                "Namespace owner mismatch for #{namespace}: R2=#{email}, SQLite=#{other_email}"
              )

            {:error, reason} ->
              Mix.raise("SQLite query failed for namespace #{namespace}: #{inspect(reason)}")
          end
        end)

        {:ok, length(r2_claims)}

      {:error, :not_found} ->
        IO.puts("No R2 namespace index found — skipping namespace verification")
        {:ok, 0}

      {:error, reason} ->
        {:error, {:namespace_index_read_failed, reason}}
    end
  end

  defp verify_indexed_documents do
    case ObjectIndex.get(R2Index.namespace_index_key()) do
      {:ok, content} ->
        r2_claims = R2Index.parse_namespace_tsv(content)

        {total_docs, missing_docs} =
          Enum.reduce(r2_claims, {0, []}, fn {namespace, _email}, {total, missing} ->
            page_key = R2Index.page_index_key(namespace)

            case ObjectIndex.get(page_key) do
              {:ok, page_content} ->
                entries = R2Index.parse_page_ndjson(page_content)

                Enum.reduce(entries, {total, missing}, fn entry, {t, m} ->
                  full_path = reconstruct_full_path(namespace, entry.path)

                  case SqliteDocuments.missing_paths([full_path]) do
                    [] -> {t + 1, m}
                    _ -> {t + 1, [full_path | m]}
                  end
                end)

              {:error, :not_found} ->
                IO.puts("  Page index missing for namespace: #{namespace}")
                {total, missing}

              {:error, reason} ->
                Mix.raise("Failed to read page index for #{namespace}: #{inspect(reason)}")
            end
          end)

        if missing_docs != [] do
          IO.puts("\nMissing documents in SQLite:")

          Enum.each(missing_docs, fn path ->
            IO.puts("  - #{path}")
          end)

          {:error, {:missing_documents, length(missing_docs)}}
        else
          IO.puts("Indexed documents verified: #{total_docs}")
          {:ok, total_docs}
        end

      {:error, :not_found} ->
        IO.puts("No R2 namespace index found — skipping document verification")
        {:ok, 0}

      {:error, reason} ->
        {:error, {:namespace_index_read_failed, reason}}
    end
  end

  defp reconstruct_full_path(namespace, "/"), do: "/" <> namespace
  defp reconstruct_full_path(namespace, "/" <> rest), do: "/" <> namespace <> "/" <> rest
end
