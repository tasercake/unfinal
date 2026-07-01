defmodule Mix.Tasks.Unfinal.ExportSqliteToR2 do
  @shortdoc "Export SQLite data to R2 for rollback readiness"
  @moduledoc """
  Idempotent rollback-readiness task. Reads SQLite as source of truth and
  writes R2-compatible artifacts: document objects, per-namespace NDJSON page
  indexes, and indexes/namespaces.txt.

  Run before planned R2-primary rollback:

      MIX_ENV=prod mix unfinal.export_sqlite_to_r2

  Re-running is safe (idempotent).
  """

  use Mix.Task
  require Logger

  alias Unfinal.R2Index
  alias Unfinal.SqliteDocuments
  alias Unfinal.S3ObjectStore
  alias Unfinal.Repo

  @impl true
  def run(_args) do
    Mix.Task.run("app.start", ["--no-start"])
    {:ok, _} = Application.ensure_all_started(:unfinal)

    IO.puts("\n=== SQLite → R2 Export (Rollback Readiness) ===\n")

    with {:ok, ns_count} <- export_namespace_claims(),
         {:ok, doc_count, page_count} <- export_documents_and_pages() do
      IO.puts("\n=== Summary ===")
      IO.puts("Namespace claims exported: #{ns_count}")
      IO.puts("Documents exported: #{doc_count}")
      IO.puts("Page indexes exported: #{page_count}")
      IO.puts("\n✅ SQLite-to-R2 export complete\n")
    else
      {:error, reason} ->
        IO.puts("\n❌ SQLite-to-R2 export FAILED: #{inspect(reason)}\n")
        Mix.raise("SQLite-to-R2 export failed: #{inspect(reason)}")
    end
  end

  defp export_namespace_claims do
    sql = "SELECT namespace, email FROM namespace_claims ORDER BY namespace"

    case Repo.query(sql, [], timeout: 5_000) do
      {:ok, %{rows: rows}} ->
        claims = Enum.map(rows, fn [ns, email] -> {ns, email} end)
        content = R2Index.serialize_namespace_index(claims)

        case S3ObjectStore.put_object(R2Index.namespace_index_key(), content) do
          :ok ->
            IO.puts("  Namespace index exported: #{length(claims)} claims")
            {:ok, length(claims)}

          {:error, reason} ->
            {:error, {:namespace_index_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:namespace_query_failed, reason}}
    end
  end

  defp export_documents_and_pages do
    sql = "SELECT DISTINCT namespace FROM documents ORDER BY namespace"

    case Repo.query(sql, [], timeout: 5_000) do
      {:ok, %{rows: namespaces}} ->
        Enum.reduce_while(namespaces, {:ok, 0, 0}, fn [namespace],
                                                      {:ok, total_docs, total_pages} ->
          case export_namespace(namespace) do
            {:ok, doc_count} ->
              {:cont, {:ok, total_docs + doc_count, total_pages + 1}}

            {:error, reason} ->
              {:halt, {:error, {:namespace_export_failed, namespace, reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {:namespace_query_failed, reason}}
    end
  end

  defp export_namespace(namespace) do
    entries = SqliteDocuments.list_namespace(namespace)

    # Write page index NDJSON
    page_content = R2Index.serialize_page_index(entries)
    page_key = R2Index.page_index_key(namespace)

    case S3ObjectStore.put_object(page_key, page_content) do
      :ok ->
        export_namespace_documents(namespace)

      {:error, reason} ->
        Logger.warning("Failed to write page index for #{namespace}: #{inspect(reason)}")
        {:error, {:page_index_write_failed, namespace, reason}}
    end
  end

  defp export_namespace_documents(namespace) do
    doc_sql = """
    SELECT path, content, revision FROM documents
    WHERE namespace = ?1 AND content != ''
    ORDER BY path
    """

    case Repo.query(doc_sql, [namespace], timeout: 5_000) do
      {:ok, %{rows: rows}} ->
        Enum.reduce_while(rows, {:ok, 0}, fn [path, content, _revision], {:ok, count} ->
          key = Unfinal.ContentStore.object_key(path)

          case S3ObjectStore.put_object(key, content) do
            :ok ->
              {:cont, {:ok, count + 1}}

            {:error, reason} ->
              Logger.warning("Failed to export document #{path}: #{inspect(reason)}")
              {:halt, {:error, {:document_write_failed, path, reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {:document_query_failed, namespace, reason}}
    end
  end
end
