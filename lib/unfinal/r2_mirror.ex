defmodule Unfinal.R2Mirror do
  @moduledoc """
  Best-effort async R2 mirroring for rollback safety.

  After each successful SQLite primary write, callers start a supervised async
  task via this module to mirror the affected R2 artifacts (document objects,
  page NDJSON indexes, namespace TSV index).

  Failures are logged with path/namespace context but never fail the SQLite
  write. Rollback readiness is established by running the idempotent
  `mix unfinal.export_sqlite_to_r2` task, not by continuously retried workers.

  KISS: async task + log on failure. No persistent outbox, retry scheduler, or
  supervised worker.
  """

  require Logger

  alias Unfinal.R2Index
  alias Unfinal.S3ObjectStore

  @doc """
  Mirror a document object to R2 (best-effort, async).

  Spawns a supervised task under `Unfinal.DocumentTaskSupervisor` that writes
  the document content to the legacy R2 object key. Returns `:ok` immediately.

  On R2 write failure, the task logs a warning with the document path.
  """
  @spec mirror_document_async(String.t(), String.t()) :: :ok
  def mirror_document_async(path, content) when is_binary(path) and is_binary(content) do
    r2_dual_write? = Application.get_env(:unfinal, :r2_dual_write, false)

    if r2_dual_write? do
      _ref =
        Task.Supervisor.async_nolink(Unfinal.DocumentTaskSupervisor, fn ->
          r2_key = Unfinal.ContentStore.object_key(path)

          case S3ObjectStore.put_object(r2_key, content) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "best-effort R2 document mirror failed for #{inspect(path)}: #{inspect(reason)}"
              )
          end
        end)
    end

    :ok
  end

  @doc """
  Mirror a namespace's page index to R2 as NDJSON (best-effort, async).

  Spawns a supervised task under `Unfinal.DocumentTaskSupervisor` that writes
  the page index NDJSON to the legacy R2 object key. Returns `:ok` immediately.

  On R2 write failure, the task logs a warning with the namespace.
  """
  @spec mirror_page_index_async(String.t(), [%{path: String.t(), updated_at: String.t()}]) :: :ok
  def mirror_page_index_async(namespace, entries)
      when is_binary(namespace) and is_list(entries) do
    r2_dual_write? = Application.get_env(:unfinal, :r2_dual_write, false)

    if r2_dual_write? do
      _ref =
        Task.Supervisor.async_nolink(Unfinal.DocumentTaskSupervisor, fn ->
          case R2Index.write_page_index(namespace, entries) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "best-effort R2 page index mirror failed for namespace #{inspect(namespace)}: #{inspect(reason)}"
              )
          end
        end)
    end

    :ok
  end

  @doc """
  Mirror the full namespace index to R2 as TSV (best-effort, async).

  Spawns a supervised task under `Unfinal.DocumentTaskSupervisor` that writes
  the namespace TSV index to the legacy R2 object key. Returns `:ok` immediately.

  On R2 write failure, the task logs a warning.
  """
  @spec mirror_namespace_index_async(%{String.t() => %{email: String.t()}}) :: :ok
  def mirror_namespace_index_async(claims) when is_map(claims) do
    r2_dual_write? = Application.get_env(:unfinal, :r2_dual_write, false)

    if r2_dual_write? do
      _ref =
        Task.Supervisor.async_nolink(Unfinal.DocumentTaskSupervisor, fn ->
          case R2Index.write_namespace_index(claims) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("best-effort R2 namespace index mirror failed: #{inspect(reason)}")
          end
        end)
    end

    :ok
  end
end
