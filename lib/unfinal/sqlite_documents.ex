defmodule Unfinal.SqliteDocuments do
  @moduledoc """
  SQLite-primary document reads, writes, and verification helpers.

  All functions use `Unfinal.Repo` directly (single writer pool) and never
  fall back to R2. Fallback-to-R2 repair lives in `Unfinal.SqliteContentStore`.

  Path mapping:
  - `/namespace` → namespace = "namespace", relative_path = "/"
  - `/namespace/rest` → namespace = "namespace", relative_path = "/rest"
  - `/` → skipped as `:ignored` (no namespace segment)
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
    sql = "SELECT path, content, revision, updated_at FROM documents WHERE path = ?1 LIMIT 1"

    case query(sql, [path]) do
      {:ok, %{rows: [[^path, content, revision, updated_at]]}} ->
        {:ok, build_doc(path, content, revision, updated_at)}

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
  @spec put(String.t(), String.t(), String.t() | nil, non_neg_integer()) ::
          {:ok, Document.t()} | {:stale, Document.t()} | {:error, term()}
  def put(path, content, nil, 0) do
    with {:ok, {namespace, relative_path}} <- parts(path) do
      now_iso = DateTime.to_iso8601(DateTime.utc_now())

      sql =
        "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) " <>
          "VALUES (?1, ?2, ?3, ?4, 1, ?5)"

      case query(sql, [path, namespace, relative_path, content, now_iso]) do
        {:ok, %{num_rows: 1}} -> {:ok, build_doc(path, content, 1, now_iso)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def put(path, content, _base_etag, base_revision)
      when is_binary(path) and is_integer(base_revision) and base_revision > 0 do
    with {:ok, {_ns, _rel}} <- parts(path) do
      now_iso = DateTime.to_iso8601(DateTime.utc_now())
      new_rev = base_revision + 1

      sql =
        "UPDATE documents SET content = ?1, revision = ?2, updated_at = ?3 " <>
          "WHERE path = ?4 AND revision = ?5"

      case query(sql, [content, new_rev, now_iso, path, base_revision]) do
        {:ok, %{num_rows: 1}} ->
          {:ok, build_doc(path, content, new_rev, now_iso)}

        {:ok, %{num_rows: 0}} ->
          {:stale, fetch_latest!(path)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def put(_path, _content, _base_etag, _base_revision), do: {:error, :invalid_base}

  @doc """
  Insert a document row from R2 fallback repair. ON CONFLICT DO NOTHING.
  """
  @spec insert_missing_from_r2(String.t(), Document.t()) :: :ok | {:error, term()}
  def insert_missing_from_r2(path, %Document{} = doc) when is_binary(path) do
    with {:ok, {ns, rel}} <- parts(path) do
      iso = DateTime.to_iso8601(DateTime.utc_now())

      sql =
        "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) " <>
          "VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(path) DO NOTHING"

      case query(sql, [path, ns, rel, doc.content, doc.revision, iso]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ignored -> :ok
    end
  end

  @doc """
  Touch a page: insert placeholder with empty content if absent; update
  `updated_at` only when the target row is not already newer.
  """
  @spec touch_page(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def touch_page(namespace, relative_path, updated_at)
      when is_binary(namespace) and is_binary(relative_path) and is_binary(updated_at) do
    path = full_path(namespace, relative_path)

    insert_sql =
      "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) " <>
        "VALUES (?1, ?2, ?3, '', 0, ?4) ON CONFLICT(path) DO NOTHING"

    case query(insert_sql, [path, namespace, relative_path, updated_at]) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        update_sql = "UPDATE documents SET updated_at = ?1 WHERE path = ?2 AND updated_at < ?1"

        case query(update_sql, [updated_at, path]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List namespace documents ordered by `updated_at` DESC.
  Returns `[%{path: String.t(), updated_at: String.t()}]` with namespace-relative paths.
  """
  @spec list_namespace(String.t()) :: [%{path: String.t(), updated_at: String.t()}]
  def list_namespace(namespace) when is_binary(namespace) do
    sql =
      "SELECT relative_path, updated_at FROM documents WHERE namespace = ?1 ORDER BY updated_at DESC"

    case query(sql, [namespace]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [rel, upd] -> %{path: rel, updated_at: upd} end)

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

  # ── Private ──────────────────────────────────────────────────────────────────

  defp build_doc(path, content, revision, updated_at) do
    etag =
      :crypto.hash(:sha256, "#{revision}:#{updated_at}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    %Document{path: path, content: content, etag: etag, revision: revision, write_id: nil}
  end

  defp fetch_latest!(path) do
    case fetch(path) do
      {:ok, doc} ->
        doc

      {:error, :not_found} ->
        %Document{path: path, content: "", etag: nil, revision: 0, write_id: nil}

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
  defp parts("/"), do: :ignored

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
