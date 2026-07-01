defmodule Unfinal.SqliteContentStore do
  @moduledoc """
  ContentStore adapter for SQLite-primary mode with temporary R2 dual-write.

  - Reads come from SQLite first; R2 read-fallback repairs missing SQLite rows
    (insert-if-absent only, never overwrites newer SQLite data).
  - Writes go to SQLite first; on success, best-effort async R2 mirror is kicked off.
  - SQLite write failures do NOT trigger R2 mirrors.
  """

  @behaviour Unfinal.ContentStore

  require Logger

  alias Unfinal.ContentStore
  alias Unfinal.ContentStore.Document
  alias Unfinal.R2Mirror
  alias Unfinal.S3ObjectStore
  alias Unfinal.SqliteDocuments

  # ── get/1 ─────────────────────────────────────────────────────────────────────

  @impl true
  def get(path) do
    normalized = ContentStore.normalize_path(path)

    case SqliteDocuments.fetch(normalized) do
      {:ok, %Document{} = doc} ->
        {:ok, doc}

      {:error, :not_found} ->
        if Application.get_env(:unfinal, :r2_read_fallback, false) do
          handle_r2_fallback(normalized)
        else
          {:ok, ContentStore.missing(normalized)}
        end

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
        R2Mirror.mirror_document_async(normalized, content)
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
        if Application.get_env(:unfinal, :r2_dual_write, false) do
          Task.Supervisor.async_nolink(Unfinal.DocumentTaskSupervisor, fn ->
            r2_key = ContentStore.object_key(normalized)

            case S3ObjectStore.put_object(r2_key, "") do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "best-effort R2 delete mirror failed for #{normalized}: #{inspect(reason)}"
                )
            end
          end)
        end

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

  # ── Private: R2 read fallback with repair ─────────────────────────────────────

  defp handle_r2_fallback(path) do
    case S3ObjectStore.get(path) do
      {:ok, %Document{etag: nil, revision: 0, content: ""}} ->
        {:ok, ContentStore.missing(path)}

      {:ok, %Document{} = r2_doc} ->
        if present_document?(r2_doc) do
          SqliteDocuments.insert_missing_from_r2(path, r2_doc)

          case SqliteDocuments.fetch(path) do
            {:ok, %Document{} = sqlite_doc} -> {:ok, sqlite_doc}
            {:error, :not_found} -> {:ok, r2_doc}
            {:error, _} -> {:ok, r2_doc}
          end
        else
          {:ok, ContentStore.missing(path)}
        end

      {:ok, _missing} ->
        {:ok, ContentStore.missing(path)}

      {:error, reason} ->
        Logger.warning("R2 read fallback failed for #{path}: #{inspect(reason)}")
        {:ok, ContentStore.missing(path)}
    end
  end

  defp present_document?(%Document{} = doc) do
    doc.etag != nil or doc.revision > 0 or doc.write_id != nil or doc.content != ""
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
