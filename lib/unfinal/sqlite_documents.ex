defmodule Unfinal.SqliteDocuments do
  @moduledoc """
  SQLite-primary document reads, writes, and verification helpers.

  All functions use `Unfinal.Repo` directly (single writer pool).

  Path mapping:
  - `/namespace` → namespace = "namespace", relative_path = "/"
  - `/namespace/rest` → namespace = "namespace", relative_path = "/rest"
  - `/` → namespace = nil, relative_path = "/"
  """

  alias Unfinal.ContentStore.Document
  alias Unfinal.Repo

  @query_timeout 1_000

  @doc """
  Fetch a document from SQLite. Returns `{:ok, doc}` or `{:error, :not_found}`.

  Distinguishes between a persisted empty document row (returns ok) and a
  missing row (returns :not_found).
  """
  @spec fetch(String.t()) :: {:ok, Document.t()} | {:error, :not_found | term()}
  def fetch(path) when is_binary(path) do
    sql =
      "SELECT path, title, content, revision, updated_at FROM documents WHERE path = ?1 LIMIT 1"

    case query(sql, [path]) do
      {:ok, %{rows: [[^path, title, content, revision, updated_at]]}} ->
        {:ok, build_doc(path, title, content, revision, updated_at)}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Primary CAS write. Revision increments only when `base_revision` matches.

  - New rows (base_etag == nil, base_revision == 0): INSERT with revision 1.
  - Existing rows: UPDATE only when base_revision matches.
  Returns `{:ok, doc}` | `{:stale, doc}` | `{:error, reason}`.
  """
  @spec put(String.t(), String.t(), String.t(), String.t() | nil, non_neg_integer()) ::
          {:ok, Document.t()} | {:stale, Document.t()} | {:error, term()}
  def put(path, title, content, nil, 0) do
    with :ok <- ensure_writable_path(path),
         {:ok, {namespace, relative_path}} <- parts(path) do
      now_iso = DateTime.to_iso8601(DateTime.utc_now())

      # INSERT or upgrade a placeholder row (revision 0 from touch_page) to revision 1
      sql =
        "INSERT INTO documents(path, namespace, relative_path, title, content, revision, updated_at) " <>
          "VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6) " <>
          "ON CONFLICT(path) DO UPDATE SET title = excluded.title, content = excluded.content, revision = 1, updated_at = excluded.updated_at WHERE documents.revision = 0"

      case query(sql, [path, namespace, relative_path, title, content, now_iso]) do
        {:ok, %{num_rows: 1}} -> {:ok, build_doc(path, title, content, 1, now_iso)}
        {:ok, %{num_rows: 0}} -> {:stale, fetch_latest!(path)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def put(path, title, content, _base_etag, base_revision)
      when is_binary(path) and is_binary(title) and is_binary(content) and
             is_integer(base_revision) and base_revision > 0 do
    with :ok <- ensure_writable_path(path),
         {:ok, {_ns, _rel}} <- parts(path) do
      now_iso = DateTime.to_iso8601(DateTime.utc_now())
      new_rev = base_revision + 1

      sql =
        "UPDATE documents SET title = ?1, content = ?2, revision = ?3, updated_at = ?4 " <>
          "WHERE path = ?5 AND revision = ?6"

      case query(sql, [title, content, new_rev, now_iso, path, base_revision]) do
        {:ok, %{num_rows: 1}} ->
          {:ok, build_doc(path, title, content, new_rev, now_iso)}

        {:ok, %{num_rows: 0}} ->
          {:stale, fetch_latest!(path)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def put(_path, _title, _content, _base_etag, _base_revision), do: {:error, :invalid_base}

  @doc """
  Touch a page: insert placeholder with empty content if absent; update
  `updated_at` only when the target row is not already newer.
  """
  @spec touch_page(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def touch_page(namespace, relative_path, updated_at, title)
      when is_binary(namespace) and is_binary(relative_path) and is_binary(updated_at) and
             is_binary(title) do
    path = full_path(namespace, relative_path)

    with :ok <- ensure_writable_path(path) do
      do_touch_page(path, namespace, relative_path, updated_at, title)
    end
  end

  defp do_touch_page(path, namespace, relative_path, updated_at, title) do
    insert_sql =
      "INSERT INTO documents(path, namespace, relative_path, title, content, revision, updated_at) " <>
        "VALUES (?1, ?2, ?3, ?4, '', 0, ?5) ON CONFLICT(path) DO NOTHING"

    case query(insert_sql, [path, namespace, relative_path, title, updated_at]) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        update_sql =
          "UPDATE documents SET title = ?1, " <>
            "updated_at = CASE WHEN updated_at < ?2 THEN ?2 ELSE updated_at END WHERE path = ?3"

        case query(update_sql, [title, updated_at, path]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List namespace documents ordered by `updated_at` DESC.
  Returns title metadata with namespace-relative paths.
  """
  @spec list_namespace(String.t()) :: [
          %{path: String.t(), title: String.t(), updated_at: String.t()}
        ]
  def list_namespace(namespace) when is_binary(namespace) do
    sql =
      "SELECT relative_path, title, updated_at FROM documents WHERE namespace = ?1 ORDER BY updated_at DESC"

    case query(sql, [namespace]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [rel, title, upd] -> %{path: rel, title: title, updated_at: upd} end)

      {:error, _} ->
        []
    end
  end

  @doc "List most recently edited documents across all namespaces."
  @spec recent_edits(non_neg_integer()) :: [
          %{path: String.t(), title: String.t(), updated_at: String.t()}
        ]
  def recent_edits(limit \\ 20) when is_integer(limit) and limit > 0 do
    sql =
      "SELECT path, title, updated_at FROM documents WHERE updated_at IS NOT NULL ORDER BY updated_at DESC LIMIT ?1"

    case query(sql, [limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [path, title, upd] -> %{path: path, title: title, updated_at: upd} end)

      {:error, _} ->
        []
    end
  end

  @doc "Count all document rows."
  @spec count_documents() :: non_neg_integer()
  def count_documents do
    case query("SELECT COUNT(*) FROM documents", []) do
      {:ok, %{rows: [[n]]}} -> n
      _ -> 0
    end
  end

  @doc "Return paths from the given list that are absent from SQLite."
  @spec missing_paths([String.t()]) :: [String.t()]
  def missing_paths([]), do: []

  def missing_paths(paths) when is_list(paths) do
    Enum.reject(paths, fn p ->
      case query("SELECT 1 FROM documents WHERE path = ?1 LIMIT 1", [p]) do
        {:ok, %{rows: [[1]]}} -> true
        _ -> false
      end
    end)
  end

  @doc "Move one document and reserve its old path as a permanent redirect."
  @spec move(String.t(), String.t()) :: :ok | {:error, term()}
  def move(source_path, target_path)
      when is_binary(source_path) and is_binary(target_path) do
    with {:ok, {namespace, _source_relative_path}} <- parts(source_path),
         {:ok, {^namespace, target_relative_path}} <- parts(target_path),
         false <- source_path == target_path do
      case Repo.transaction(fn ->
             move_in_transaction(
               source_path,
               target_path,
               namespace,
               target_relative_path
             )
           end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      true -> {:error, :same_path}
      {:ok, {_other_namespace, _relative_path}} -> {:error, :cross_namespace}
      _other -> {:error, :invalid_path}
    end
  end

  def move(_source_path, _target_path), do: {:error, :invalid_path}

  @doc "Resolve a path to a document, permanent redirect, or missing page."
  @spec resolve_path(String.t()) :: :document | {:redirect, String.t()} | :missing
  def resolve_path(path) when is_binary(path) do
    case query("SELECT 1 FROM documents WHERE path = ?1 LIMIT 1", [path]) do
      {:ok, %{rows: [[1]]}} ->
        :document

      _other ->
        case query(
               "SELECT target_path FROM document_redirects WHERE source_path = ?1 LIMIT 1",
               [path]
             ) do
          {:ok, %{rows: [[target_path]]}} -> {:redirect, target_path}
          _other -> :missing
        end
    end
  end

  def resolve_path(_path), do: :missing

  # ── Private ──────────────────────────────────────────────────────────────────

  defp build_doc(path, title, content, revision, updated_at) do
    etag =
      :crypto.hash(:sha256, "#{revision}:#{updated_at}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    %Document{
      path: path,
      title: title,
      content: content,
      etag: etag,
      revision: revision,
      write_id: nil
    }
  end

  defp move_in_transaction(source_path, target_path, namespace, target_relative_path) do
    with :ok <- ensure_source_exists(source_path),
         :ok <- ensure_destination_available(target_path),
         :ok <- collapse_redirects(source_path, target_path),
         :ok <- insert_redirect(source_path, target_path, namespace),
         :ok <- update_document_path(source_path, target_path, target_relative_path) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_source_exists(path) do
    case query("SELECT 1 FROM documents WHERE path = ?1 LIMIT 1", [path]) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_writable_path(path) do
    case query("SELECT 1 FROM document_redirects WHERE source_path = ?1 LIMIT 1", [path]) do
      {:ok, %{rows: []}} -> :ok
      {:ok, %{rows: [[1]]}} -> {:error, :path_redirected}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_destination_available(path) do
    sql =
      "SELECT 1 FROM documents WHERE path = ?1 " <>
        "UNION ALL SELECT 1 FROM document_redirects WHERE source_path = ?1 LIMIT 1"

    case query(sql, [path]) do
      {:ok, %{rows: []}} -> :ok
      {:ok, %{rows: _rows}} -> {:error, :destination_taken}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collapse_redirects(source_path, target_path) do
    case query(
           "UPDATE document_redirects SET target_path = ?1 WHERE target_path = ?2",
           [target_path, source_path]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_redirect(source_path, target_path, namespace) do
    sql =
      "INSERT INTO document_redirects(source_path, target_path, namespace, created_at) " <>
        "VALUES (?1, ?2, ?3, ?4)"

    case query(sql, [source_path, target_path, namespace, DateTime.to_iso8601(DateTime.utc_now())]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_document_path(source_path, target_path, target_relative_path) do
    sql = "UPDATE documents SET path = ?1, relative_path = ?2 WHERE path = ?3"

    case query(sql, [target_path, target_relative_path, source_path]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_latest!(path) do
    case fetch(path) do
      {:ok, doc} ->
        doc

      {:error, :not_found} ->
        %Document{path: path, title: "", content: "", etag: nil, revision: 0, write_id: nil}

      {:error, reason} ->
        raise "failed to read latest SQLite document for #{path}: #{inspect(reason)}"
    end
  end

  defp query(sql, params) do
    try do
      Repo.query(sql, params, timeout: @query_timeout)
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  # Path → {namespace, relative_path} or :ignored
  defp parts("/"), do: {:ok, {nil, "/"}}

  defp parts("/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [ns] when ns != "" ->
        if Unfinal.DocumentPath.valid_segment?(ns), do: {:ok, {ns, "/"}}, else: :ignored

      [ns, rel] when ns != "" and rel != "" ->
        frel = "/" <> rel

        if Unfinal.DocumentPath.valid_segment?(ns) and
             Unfinal.DocumentPath.valid_relative_path?(frel),
           do: {:ok, {ns, frel}},
           else: :ignored

      _ ->
        :ignored
    end
  end

  defp parts(_), do: :ignored

  defp full_path(ns, "/"), do: "/" <> ns
  defp full_path(ns, rel), do: "/" <> ns <> rel
end
