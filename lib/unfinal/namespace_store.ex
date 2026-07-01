defmodule Unfinal.NamespaceStore do
  @moduledoc """
  Namespace ownership store backed by SQLite.
  """

  require Logger

  @type namespace :: String.t()
  @type email :: String.t()
  @type owner :: %{email: email()}

  @spec valid_namespace?(term()) :: boolean()
  def valid_namespace?(namespace), do: Unfinal.DocumentPath.valid_segment?(namespace)

  @spec claim(namespace(), map()) :: :ok | {:error, :invalid | :taken | :already_claimed}
  def claim(namespace, %{"email" => email}) when is_binary(email) do
    cond do
      not valid_namespace?(namespace) ->
        {:error, :invalid}

      true ->
        now = DateTime.to_iso8601(DateTime.utc_now())

        sql =
          "INSERT OR IGNORE INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)"

        case repo_query(sql, [namespace, email, now]) do
          {:ok, %{num_rows: 1}} ->
            :ok

          {:ok, %{num_rows: 0}} ->
            classify_claim_conflict(namespace, email)

          {:error, reason} ->
            Logger.error("namespace claim insert failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  def claim(_namespace, _user), do: {:error, :invalid}

  @spec owner(namespace()) :: owner() | nil
  def owner(namespace) do
    sql = "SELECT email FROM namespace_claims WHERE namespace = ?1 LIMIT 1"

    case repo_query(sql, [namespace]) do
      {:ok, %{rows: [[email]]}} -> %{email: email}
      _ -> nil
    end
  end

  @spec taken?(namespace()) :: boolean()
  def taken?(namespace), do: not is_nil(owner(namespace))

  @spec namespace_for_email(email()) :: namespace() | nil
  def namespace_for_email(email) when is_binary(email) do
    sql = "SELECT namespace FROM namespace_claims WHERE email = ?1 LIMIT 1"

    case repo_query(sql, [email]) do
      {:ok, %{rows: [[namespace]]}} -> namespace
      _ -> nil
    end
  end

  def namespace_for_email(_email), do: nil

  @spec clear() :: :ok
  def clear do
    repo_query("DELETE FROM namespace_claims", [])
    :ok
  end

  # -- Private helpers --

  defp classify_claim_conflict(namespace, email) do
    check_sql =
      "SELECT namespace, email FROM namespace_claims WHERE namespace = ?1 OR email = ?2 LIMIT 2"

    case repo_query(check_sql, [namespace, email]) do
      {:ok, %{rows: rows}} ->
        has_namespace = Enum.any?(rows, fn [ns, _] -> ns == namespace end)
        has_email = Enum.any?(rows, fn [_, em] -> em == email end)

        cond do
          has_namespace and has_email -> {:error, :already_claimed}
          has_namespace -> {:error, :taken}
          has_email -> {:error, :already_claimed}
          true -> {:error, :taken}
        end

      {:error, reason} ->
        Logger.error("namespace claim conflict check failed: #{inspect(reason)}")
        {:error, :taken}
    end
  end

  defp repo_query(sql, params) do
    try do
      Unfinal.Repo.query(sql, params, timeout: 1_000)
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end
end
