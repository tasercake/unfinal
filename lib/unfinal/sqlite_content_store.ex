defmodule Unfinal.SqliteContentStore do
  @moduledoc """
  ContentStore adapter for SQLite-primary mode.

  All reads and writes go to SQLite exclusively. No R2 fallback or dual-write.
  """

  @behaviour Unfinal.ContentStore

  require Logger

  alias Unfinal.ContentStore
  alias Unfinal.ContentStore.Document
  alias Unfinal.SqliteDocuments

  # ── get/1 ─────────────────────────────────────────────────────────────────────

  @impl true
  def get(path) do
    normalized = ContentStore.normalize_path(path)

    case SqliteDocuments.fetch(normalized) do
      {:ok, %Document{} = doc} ->
        {:ok, doc}

      {:error, :not_found} ->
        {:ok, ContentStore.missing(normalized)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── put/4 ─────────────────────────────────────────────────────────────────────

  @impl true
  def put(path, content, base_etag, base_revision) do
    normalized = ContentStore.normalize_path(path)

    case SqliteDocuments.put(normalized, content, base_etag, base_revision) do
      {:ok, %Document{} = doc} ->
        {:ok, doc}

      {:stale, %Document{} = doc} ->
        {:stale, doc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── delete/3 ──────────────────────────────────────────────────────────────────

  @impl true
  def delete(path, nil, 0) do
    {:ok, ContentStore.missing(ContentStore.normalize_path(path))}
  end

  def delete(path, base_etag, base_revision) when is_binary(base_etag) do
    normalized = ContentStore.normalize_path(path)

    case sqlite_delete(normalized, base_revision) do
      {:ok, doc} ->
        {:ok, doc}

      other ->
        other
    end
  end

  def delete(path, _base_etag, _base_revision) do
    normalized = ContentStore.normalize_path(path)

    case SqliteDocuments.fetch(normalized) do
      {:ok, doc} -> {:stale, doc}
      {:error, :not_found} -> {:stale, ContentStore.missing(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── clear/0 ───────────────────────────────────────────────────────────────────

  @impl true
  def clear do
    if Mix.env() == :test do
      try do
        Unfinal.Repo.query("DELETE FROM documents", [], timeout: 5_000)
        Unfinal.Repo.query("DELETE FROM namespace_claims", [], timeout: 5_000)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ── Private: SQLite CAS delete ────────────────────────────────────────────────

  defp sqlite_delete(path, base_revision) when base_revision > 0 do
    sql = "DELETE FROM documents WHERE path = ?1 AND revision = ?2"

    try do
      case Unfinal.Repo.query(sql, [path, base_revision], timeout: 1_000) do
        {:ok, %{num_rows: 1}} ->
          {:ok, ContentStore.missing(path)}

        {:ok, %{num_rows: 0}} ->
          case SqliteDocuments.fetch(path) do
            {:ok, doc} -> {:stale, doc}
            {:error, :not_found} -> {:stale, ContentStore.missing(path)}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp sqlite_delete(_path, _base_revision), do: {:error, :invalid_base}
end
