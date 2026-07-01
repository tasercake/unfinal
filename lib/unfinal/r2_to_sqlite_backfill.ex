defmodule Unfinal.R2ToSQLiteBackfill do
  @moduledoc """
  Idempotent backfill from R2 indexes into SQLite.

  Reads namespace claims and page indexes from R2/object storage,
  reconstructs full document paths, fetches documents through the
  current ContentStore adapter, and upserts into SQLite with guards
  that never overwrite rows newer than the R2 source data.

  Supports `:dry_run` and `:commit` modes. Returns a report map
  with counts and details of all operations.
  """

  alias Unfinal.ContentStore
  alias Unfinal.ContentStore.Document
  alias Unfinal.DocumentPath
  alias Unfinal.ObjectIndex
  alias Unfinal.PageIndex
  alias Unfinal.Repo

  require Logger

  @namespace_index_key "indexes/namespaces.txt"
  @legacy_claimed_at ~U[1970-01-01 00:00:00Z]

  @type option ::
          {:mode, :dry_run | :commit}
          | {:started_at, DateTime.t() | nil}
          | {:report_path, String.t() | nil}

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    started_at = Keyword.get(opts, :started_at, DateTime.utc_now())
    mode = Keyword.get(opts, :mode, :dry_run)
    report_path = Keyword.get(opts, :report_path)

    report =
      initial_report()
      |> Map.put("mode", to_string(mode))
      |> Map.put("started_at", DateTime.to_iso8601(started_at))

    case execute_backfill(mode, report) do
      {:ok, final_report} ->
        final_report =
          Map.put(final_report, "finished_at", DateTime.to_iso8601(DateTime.utc_now()))

        case write_report(report_path, final_report) do
          :ok -> {:ok, final_report}
          {:error, reason} -> {:error, {:report_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Private execution flow --

  defp execute_backfill(mode, report) do
    with {:ok, report} <- read_namespace_index(report),
         {:ok, report} <- read_page_indexes(report),
         {:ok, report} <- fetch_documents(report),
         {:ok, report} <- write_namespace_claims(mode, report),
         {:ok, report} <- write_documents(mode, report) do
      {:ok, report}
    end
  end

  # -- Step 1: Read namespace index --

  defp read_namespace_index(report) do
    case ObjectIndex.get(@namespace_index_key) do
      {:ok, content} ->
        {valid_rows, invalid_rows} = parse_namespace_tsv(content)

        {:ok,
         report
         |> Map.put("namespace_rows_valid", length(valid_rows))
         |> Map.put("namespace_rows_invalid", invalid_rows)
         |> Map.put(:_namespace_rows, valid_rows)}

      {:error, :not_found} ->
        {:ok,
         report
         |> Map.put("namespace_rows_valid", 0)
         |> Map.put("namespace_rows_invalid", [])
         |> Map.put(:_namespace_rows, [])}

      {:error, reason} ->
        {:error, {:namespace_index_read_failed, reason}}
    end
  end

  defp parse_namespace_tsv(content) do
    content
    |> String.split(["\r\n", "\n", "\r"], trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {line, line_number}, {valid, invalid} ->
      case String.split(line, "\t", parts: 3) do
        [namespace, email] ->
          cond do
            not DocumentPath.valid_segment?(namespace) ->
              {valid, [%{line: line_number, reason: "invalid namespace", text: line} | invalid]}

            not valid_email?(email) ->
              {valid, [%{line: line_number, reason: "invalid email", text: line} | invalid]}

            true ->
              {[{namespace, String.trim(email)} | valid], invalid}
          end

        _parts ->
          {valid, [%{line: line_number, reason: "not tab-separated", text: line} | invalid]}
      end
    end)
    |> then(fn {valid, invalid} -> {Enum.reverse(valid), Enum.reverse(invalid)} end)
  end

  defp valid_email?(email) when is_binary(email) do
    trimmed = String.trim(email)
    trimmed != "" and String.contains?(trimmed, "@")
  end

  # -- Step 2: Read page indexes --

  defp read_page_indexes(report) do
    namespace_rows = Map.get(report, :_namespace_rows, [])

    {keys_read, keys_missing, all_entries, entries_invalid} =
      Enum.reduce(namespace_rows, {[], [], [], []}, fn {namespace, _email},
                                                       {keys_read, keys_missing, entries,
                                                        entries_invalid} ->
        page_key = PageIndex.key(namespace)

        case ObjectIndex.get(page_key) do
          {:ok, content} ->
            {parsed_valid, parsed_invalid} = parse_page_ndjson(namespace, content)

            {page_valid, page_invalid} =
              validate_page_entries(namespace, parsed_valid)

            {[page_key | keys_read], keys_missing, page_valid ++ entries,
             parsed_invalid ++ page_invalid ++ entries_invalid}

          {:error, :not_found} ->
            {[page_key | keys_read], [page_key | keys_missing], entries, entries_invalid}

          {:error, reason} ->
            # Fatal: stop processing
            throw({:page_index_read_failed, page_key, reason})
        end
      end)

    # Deduplicate by full_path
    {deduplicated, duplicate_count} = deduplicate_by_full_path(all_entries)

    {:ok,
     report
     |> Map.put("page_index_keys_read", Enum.reverse(keys_read))
     |> Map.put("page_index_keys_missing", Enum.reverse(keys_missing))
     |> Map.put("page_index_entries_valid", length(deduplicated))
     |> Map.put("page_index_entries_invalid", entries_invalid)
     |> Map.put("page_index_entries_duplicate", duplicate_count)
     |> Map.put(:_page_entries, deduplicated)}
  catch
    {:page_index_read_failed, key, reason} ->
      {:error, {:page_index_read_failed, key, reason}}
  end

  # Parse NDJSON with strict line-level reporting (does not silently drop invalid lines)
  defp parse_page_ndjson(namespace, content) do
    content
    |> String.split(["\r\n", "\n", "\r"], trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {line, line_number}, {valid, invalid} ->
      case Jason.decode(line) do
        {:ok, %{"path" => path, "updated_at" => updated_at}} ->
          cond do
            not DocumentPath.valid_relative_path?(path) ->
              {valid,
               [
                 %{namespace: namespace, line: line_number, reason: "invalid path", text: line}
                 | invalid
               ]}

            true ->
              case DateTime.from_iso8601(updated_at) do
                {:ok, _dt, 0} ->
                  {[%{path: path, updated_at: updated_at} | valid], invalid}

                _ ->
                  {valid,
                   [
                     %{
                       namespace: namespace,
                       line: line_number,
                       reason: "invalid timestamp",
                       text: line
                     }
                     | invalid
                   ]}
              end
          end

        _ ->
          {valid,
           [
             %{namespace: namespace, line: line_number, reason: "invalid JSON", text: line}
             | invalid
           ]}
      end
    end)
    |> then(fn {valid, invalid} -> {Enum.reverse(valid), Enum.reverse(invalid)} end)
  end

  defp validate_page_entries(namespace, parsed_entries) do
    Enum.reduce(parsed_entries, {[], []}, fn %{path: relative_path, updated_at: updated_at},
                                             {valid, invalid} ->
      case reconstruct_full_path(namespace, relative_path) do
        {:ok, full_path} ->
          {[
             %{
               namespace: namespace,
               relative_path: relative_path,
               full_path: full_path,
               updated_at: updated_at
             }
             | valid
           ], invalid}

        {:error, reason} ->
          {valid,
           [%{namespace: namespace, relative_path: relative_path, reason: reason} | invalid]}
      end
    end)
  end

  defp reconstruct_full_path(namespace, relative_path) do
    full_path =
      case relative_path do
        "/" -> "/" <> namespace
        "/" <> rest -> "/" <> namespace <> "/" <> rest
      end

    # Validate the namespace segment from the full path
    case full_path do
      "/" <> rest ->
        first_segment = rest |> String.split("/", parts: 2) |> hd()

        if DocumentPath.valid_segment?(first_segment) do
          {:ok, full_path}
        else
          {:error, "invalid namespace segment in path"}
        end
    end
  end

  defp deduplicate_by_full_path(entries) do
    grouped =
      Enum.group_by(entries, & &1.full_path)

    {deduplicated, duplicate_count} =
      Enum.reduce(grouped, {[], 0}, fn {_full_path, group}, {acc, dup_count} ->
        # Sort by updated_at descending, keep first (newest)
        sorted = Enum.sort_by(group, & &1.updated_at, :desc)
        newest = hd(sorted)
        group_duplicates = length(sorted) - 1
        {[newest | acc], dup_count + group_duplicates}
      end)

    {deduplicated, duplicate_count}
  end

  # -- Step 3: Fetch documents --

  defp fetch_documents(report) do
    page_entries = Map.get(report, :_page_entries, [])
    adapter = ContentStore.adapter()

    {fetched_entries, missing_docs, fatal_errors} =
      Enum.reduce(
        page_entries,
        {[], [], []},
        fn entry, {fetched, missing, errors} ->
          full_path = entry.full_path
          expected_key = ContentStore.object_key(full_path)

          case adapter.get(full_path) do
            {:ok, %Document{etag: nil, revision: 0, content: ""}} ->
              # Missing document (adapter returns missing sentinel)
              missing_info = %{
                namespace: entry.namespace,
                relative_path: entry.relative_path,
                full_path: full_path,
                expected_key: expected_key,
                updated_at: entry.updated_at
              }

              Logger.warning("Missing indexed document: #{full_path} (key: #{expected_key})")

              {fetched, [missing_info | missing], errors}

            {:ok, %Document{} = doc} ->
              entry_with_doc =
                entry
                |> Map.put(:_doc, doc)
                |> Map.put(:_expected_key, expected_key)

              {[entry_with_doc | fetched], missing, errors}

            {:error, reason} ->
              Logger.error("Fatal error fetching document #{full_path}: #{inspect(reason)}")

              {fetched, missing, [{full_path, reason} | errors]}
          end
        end
      )

    if fatal_errors != [] do
      {:error, {:document_fetch_failures, Enum.reverse(fatal_errors)}}
    else
      {:ok,
       report
       |> Map.put("documents_expected", length(page_entries))
       |> Map.put("documents_fetched", length(fetched_entries))
       |> Map.put("missing_indexed_documents", Enum.reverse(missing_docs))
       |> Map.put(:_fetched_entries, Enum.reverse(fetched_entries))}
    end
  end

  # -- Step 4: Write namespace claims --

  defp write_namespace_claims(:dry_run, report) do
    namespace_rows = Map.get(report, :_namespace_rows, [])

    {inserted, existing, conflicts} =
      Enum.reduce(namespace_rows, {0, 0, []}, fn {namespace, email},
                                                 {inserted, existing, conflicts} ->
        case check_namespace_claim_exists(namespace, email) do
          :not_exists -> {inserted + 1, existing, conflicts}
          :exists -> {inserted, existing + 1, conflicts}
          {:conflict, details} -> {inserted, existing, [details | conflicts]}
        end
      end)

    {:ok,
     report
     |> Map.put("namespace_claims_inserted", inserted)
     |> Map.put("namespace_claims_existing", existing)
     |> Map.put("namespace_claim_conflicts", Enum.reverse(conflicts))}
  end

  defp write_namespace_claims(:commit, report) do
    namespace_rows = Map.get(report, :_namespace_rows, [])
    iso_claimed = DateTime.to_iso8601(@legacy_claimed_at)

    insert_sql = """
    INSERT OR IGNORE INTO namespace_claims(namespace, email, claimed_at)
    VALUES (?1, ?2, ?3)
    """

    select_sql = """
    SELECT namespace, email FROM namespace_claims
    WHERE namespace = ?1 OR email = ?2
    LIMIT 2
    """

    {inserted, existing, conflicts} =
      Enum.reduce(namespace_rows, {0, 0, []}, fn {namespace, email},
                                                 {inserted, existing, conflicts} ->
        try do
          case Repo.query(insert_sql, [namespace, email, iso_claimed], timeout: 1_000) do
            {:ok, %{num_rows: 1}} ->
              # New insert succeeded
              {inserted + 1, existing, conflicts}

            {:ok, %{num_rows: 0}} ->
              # Conflict — check what exists
              case Repo.query(select_sql, [namespace, email], timeout: 1_000) do
                {:ok, %{rows: [[^namespace, ^email]]}} ->
                  # Exact match — already existed
                  {inserted, existing + 1, conflicts}

                {:ok, %{rows: rows}} ->
                  # Namespace or email conflicts (not an exact match) — report as conflict only
                  conflict = %{
                    namespace: namespace,
                    email: email,
                    existing: format_conflict_rows(rows)
                  }

                  {inserted, existing, [conflict | conflicts]}

                {:error, reason} ->
                  throw({:namespace_query_failed, namespace, reason})
              end

            {:error, reason} ->
              throw({:namespace_insert_failed, namespace, reason})
          end
        rescue
          e -> throw({:namespace_insert_failed, namespace, Exception.message(e)})
        catch
          :exit, reason -> throw({:namespace_insert_failed, namespace, {:exit, reason}})
        end
      end)

    {:ok,
     report
     |> Map.put("namespace_claims_inserted", inserted)
     |> Map.put("namespace_claims_existing", existing)
     |> Map.put("namespace_claim_conflicts", Enum.reverse(conflicts))}
  catch
    {:namespace_insert_failed, namespace, reason} ->
      {:error, {:namespace_insert_failed, namespace, reason}}

    {:namespace_query_failed, namespace, reason} ->
      {:error, {:namespace_query_failed, namespace, reason}}
  end

  defp check_namespace_claim_exists(namespace, email) do
    sql = """
    SELECT namespace, email FROM namespace_claims
    WHERE namespace = ?1 OR email = ?2
    LIMIT 2
    """

    case Repo.query(sql, [namespace, email], timeout: 1_000) do
      {:ok, %{rows: []}} ->
        :not_exists

      {:ok, %{rows: [[^namespace, ^email]]}} ->
        :exists

      {:ok, %{rows: rows}} ->
        {:conflict, %{namespace: namespace, email: email, existing: format_conflict_rows(rows)}}

      {:error, reason} ->
        throw({:namespace_query_failed, namespace, reason})
    end
  rescue
    e -> throw({:namespace_query_failed, namespace, Exception.message(e)})
  catch
    :exit, reason -> throw({:namespace_query_failed, namespace, {:exit, reason}})
  end

  defp format_conflict_rows(rows) do
    Enum.map(rows, fn
      [ns, email] -> %{namespace: ns, email: email}
      row -> %{raw: row}
    end)
  end

  # -- Step 5: Write documents --

  defp write_documents(:dry_run, report) do
    fetched_entries = Map.get(report, :_fetched_entries, [])

    {would_insert, would_update, would_skip_newer} =
      Enum.reduce(fetched_entries, {0, 0, []}, fn entry, {insert, update, skip} ->
        doc = Map.get(entry, :_doc)
        iso_updated = normalize_updated_at(entry.updated_at)

        case check_document_state(entry.full_path, doc.revision, iso_updated) do
          :not_exists -> {insert + 1, update, skip}
          :exists_newer_or_equal -> {insert, update, [entry.full_path | skip]}
          :exists_older -> {insert, update + 1, skip}
        end
      end)

    {:ok,
     report
     |> Map.put("documents_inserted", would_insert)
     |> Map.put("documents_updated", would_update)
     |> Map.put("documents_skipped_newer", Enum.reverse(would_skip_newer))}
  end

  defp write_documents(:commit, report) do
    fetched_entries = Map.get(report, :_fetched_entries, [])

    upsert_sql = """
    INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    ON CONFLICT(path) DO UPDATE SET
      namespace = excluded.namespace,
      relative_path = excluded.relative_path,
      content = excluded.content,
      revision = excluded.revision,
      updated_at = excluded.updated_at
    WHERE
      excluded.revision > documents.revision
      OR (
        excluded.revision = documents.revision
        AND excluded.updated_at > documents.updated_at
      )
    """

    # We track inserted vs updated by checking if the row existed before upsert
    check_sql = """
    SELECT revision, updated_at FROM documents WHERE path = ?1 LIMIT 1
    """

    {inserted, updated, skipped_newer} =
      Enum.reduce(fetched_entries, {0, 0, []}, fn entry, {inserted, updated, skipped} ->
        doc = Map.get(entry, :_doc)
        iso_updated = normalize_updated_at(entry.updated_at)

        try do
          # Check if row exists first to distinguish insert vs update
          existed =
            case Repo.query(check_sql, [entry.full_path], timeout: 1_000) do
              {:ok, %{rows: []}} -> false
              {:ok, %{rows: [[_rev, _updated]]}} -> true
              {:error, _reason} -> false
            end

          params = [
            entry.full_path,
            entry.namespace,
            entry.relative_path,
            doc.content,
            doc.revision,
            iso_updated
          ]

          case Repo.query(upsert_sql, params, timeout: 1_000) do
            {:ok, %{num_rows: 1}} ->
              if existed do
                {inserted, updated + 1, skipped}
              else
                {inserted + 1, updated, skipped}
              end

            {:ok, %{num_rows: 0}} ->
              # Row exists and is newer — skipped
              {inserted, updated, [entry.full_path | skipped]}

            {:error, reason} ->
              throw({:document_upsert_failed, entry.full_path, reason})
          end
        rescue
          e -> throw({:document_upsert_failed, entry.full_path, Exception.message(e)})
        catch
          :exit, reason -> throw({:document_upsert_failed, entry.full_path, {:exit, reason}})
        end
      end)

    {:ok,
     report
     |> Map.put("documents_inserted", inserted)
     |> Map.put("documents_updated", updated)
     |> Map.put("documents_skipped_newer", Enum.reverse(skipped_newer))}
  catch
    {:document_upsert_failed, path, reason} ->
      {:error, {:document_upsert_failed, path, reason}}
  end

  defp check_document_state(full_path, source_revision, source_updated_at) do
    sql = """
    SELECT revision, updated_at FROM documents WHERE path = ?1 LIMIT 1
    """

    case Repo.query(sql, [full_path], timeout: 1_000) do
      {:ok, %{rows: []}} ->
        :not_exists

      {:ok, %{rows: [[existing_revision, existing_updated_at]]}} ->
        cond do
          existing_revision > source_revision ->
            :exists_newer_or_equal

          existing_revision == source_revision and existing_updated_at > source_updated_at ->
            :exists_newer_or_equal

          true ->
            :exists_older
        end

      {:error, reason} ->
        throw({:document_check_failed, full_path, reason})
    end
  rescue
    e -> throw({:document_check_failed, full_path, Exception.message(e)})
  catch
    :exit, reason -> throw({:document_check_failed, full_path, {:exit, reason}})
  end

  defp normalize_updated_at(updated_at) when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, dt, 0} -> DateTime.to_iso8601(dt)
      _ -> updated_at
    end
  end

  # -- Report helpers --

  defp initial_report do
    %{
      "phase" => "r2-to-sqlite-backfill",
      "mode" => "dry_run",
      "started_at" => "",
      "finished_at" => "",
      "namespace_index_key" => @namespace_index_key,
      "namespace_rows_valid" => 0,
      "namespace_rows_invalid" => [],
      "namespace_claims_inserted" => 0,
      "namespace_claims_existing" => 0,
      "namespace_claim_conflicts" => [],
      "page_index_keys_read" => [],
      "page_index_keys_missing" => [],
      "page_index_entries_valid" => 0,
      "page_index_entries_invalid" => [],
      "page_index_entries_duplicate" => 0,
      "documents_expected" => 0,
      "documents_fetched" => 0,
      "documents_inserted" => 0,
      "documents_updated" => 0,
      "documents_skipped_newer" => [],
      "missing_indexed_documents" => [],
      "fatal_errors" => []
    }
  end

  defp write_report(nil, _report), do: :ok

  defp write_report(path, report) do
    # Remove internal keys before encoding
    clean_report =
      report
      |> Map.drop([
        :_namespace_rows,
        :_page_entries,
        :_fetched_entries
      ])

    case Jason.encode(clean_report, pretty: true) do
      {:ok, json} ->
        dir = Path.dirname(path)

        with :ok <- File.mkdir_p(dir),
             :ok <- File.write(path, json <> "\n") do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:json_encode_failed, reason}}
    end
  end
end
