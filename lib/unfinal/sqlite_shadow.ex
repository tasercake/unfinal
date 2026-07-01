defmodule Unfinal.SQLiteShadow do
  @moduledoc """
  Shadow writes to SQLite for documents and namespace claims.

  All functions in this module are idempotent and never raise. SQLite failure is
  returned as `{:error, reason}` so callers can log and continue with R2 primary.
  """

  @doc """
  Upserts a document into SQLite from an R2-successful write.

  Returns `:ignored` for paths that cannot be mapped to the minimal namespace schema.
  Returns `{:error, reason}` on Repo failure; never raises.
  """
  @spec upsert_document(Unfinal.ContentStore.Document.t(), DateTime.t()) ::
          :ok | {:error, term()} | :ignored
  def upsert_document(%Unfinal.ContentStore.Document{} = doc, %DateTime{} = updated_at) do
    case document_parts(doc.path) do
      :ignored ->
        :ignored

      {namespace, relative_path} ->
        iso_updated = iso8601(updated_at)

        sql = """
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

        params = [doc.path, namespace, relative_path, doc.content, doc.revision, iso_updated]

        try do
          case repo().query(sql, params, timeout: query_timeout()) do
            {:ok, _result} -> :ok
            {:error, reason} -> {:error, reason}
          end
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end
    end
  end

  @doc """
  Inserts a namespace claim into SQLite.

  Returns `{:error, {:namespace_claim_conflict, namespace, email, rows}}` when an existing
  claim conflicts. Callers should log and ignore conflicts because R2/index remains primary.
  """
  @spec insert_namespace_claim(String.t(), String.t(), DateTime.t()) ::
          :ok | {:error, term()}
  def insert_namespace_claim(namespace, email, %DateTime{} = claimed_at) do
    iso_claimed = iso8601(claimed_at)

    insert_sql = """
    INSERT OR IGNORE INTO namespace_claims(namespace, email, claimed_at)
    VALUES (?1, ?2, ?3)
    """

    try do
      case repo().query(insert_sql, [namespace, email, iso_claimed], timeout: query_timeout()) do
        {:ok, %{num_rows: 1}} ->
          :ok

        {:ok, %{num_rows: 0}} ->
          check_namespace_claim_conflict(namespace, email)

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  # Private helpers

  defp check_namespace_claim_conflict(namespace, email) do
    select_sql = """
    SELECT namespace, email FROM namespace_claims
    WHERE namespace = ?1 OR email = ?2
    LIMIT 2
    """

    case repo().query(select_sql, [namespace, email], timeout: query_timeout()) do
      {:ok, %{rows: [[^namespace, ^email]]}} ->
        :ok

      {:ok, %{rows: rows}} ->
        {:error, {:namespace_claim_conflict, namespace, email, rows}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp repo do
    Application.get_env(:unfinal, :sqlite_shadow_repo, Unfinal.Repo)
  end

  defp query_timeout do
    Application.get_env(:unfinal, :sqlite_shadow_timeout_ms, 1_000)
  end

  defp document_parts("/"), do: :ignored

  defp document_parts("/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [namespace] when namespace != "" ->
        if Unfinal.DocumentPath.valid_segment?(namespace),
          do: {namespace, "/"},
          else: :ignored

      [namespace, relative] when namespace != "" and relative != "" ->
        full_relative = "/" <> relative

        if Unfinal.DocumentPath.valid_segment?(namespace) and
             Unfinal.DocumentPath.valid_relative_path?(full_relative),
           do: {namespace, full_relative},
           else: :ignored

      _ ->
        :ignored
    end
  end

  defp document_parts(_), do: :ignored

  defp iso8601(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end
end
