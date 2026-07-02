defmodule Unfinal.NamespaceStore do
  @moduledoc """
  Namespace ownership store backed by SQLite.
  """

  use GenServer
  require Logger

  @type namespace :: String.t()
  @type user_id :: String.t()
  @type owner :: %{user_id: user_id()}

  @type state :: %{
          sqlite_primary: boolean()
        }

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec valid_namespace?(term()) :: boolean()
  def valid_namespace?(namespace), do: Unfinal.DocumentPath.valid_segment?(namespace)

  @spec claim(namespace(), map()) :: :ok | {:error, :invalid | :taken | :already_claimed}
  def claim(namespace, %{"id" => user_id, "email" => email}) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:claim, namespace, user_id, email})
  end

  def claim(_namespace, _user), do: {:error, :invalid}

  @spec owner(namespace()) :: owner() | nil
  def owner(namespace), do: GenServer.call(__MODULE__, {:owner, namespace})

  @spec taken?(namespace()) :: boolean()
  def taken?(namespace), do: not is_nil(owner(namespace))

  @spec namespace_for_user_id(user_id()) :: namespace() | nil
  def namespace_for_user_id(user_id) when is_binary(user_id),
    do: GenServer.call(__MODULE__, {:namespace_for_user_id, user_id})

  def namespace_for_user_id(_user_id), do: nil

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  # -- GenServer callbacks --

  @impl true
  def init(_state) do
    sqlite_primary = Application.get_env(:unfinal, :storage_mode) == :sqlite

    {:ok, %{sqlite_primary: sqlite_primary}}
  end

  # ── SQLite primary claim ───────────────────────────────────────────────────

  @impl true
  def handle_call({:claim, namespace, user_id, email}, _from, %{sqlite_primary: true} = state) do
    cond do
      not valid_namespace?(namespace) ->
        {:reply, {:error, :invalid}, state}

      true ->
        now = DateTime.to_iso8601(DateTime.utc_now())

        # Store both user_id (canonical linking key) and email (NOT NULL, backward compat)
        sql =
          "INSERT OR IGNORE INTO namespace_claims(namespace, user_id, email, claimed_at) VALUES (?1, ?2, ?3, ?4)"

        case repo_query(sql, [namespace, user_id, email, now]) do
          {:ok, %{num_rows: 1}} ->
            {:reply, :ok, state}

          {:ok, %{num_rows: 0}} ->
            # Conflict — determine if taken or already_claimed using user_id
            check_sql =
              "SELECT namespace, user_id FROM namespace_claims WHERE namespace = ?1 OR user_id = ?2 LIMIT 2"

            case repo_query(check_sql, [namespace, user_id]) do
              {:ok, %{rows: rows}} ->
                has_namespace = Enum.any?(rows, fn [ns, _] -> ns == namespace end)
                has_user_id = Enum.any?(rows, fn [_, uid] -> uid == user_id end)

                cond do
                  has_namespace and has_user_id -> {:reply, {:error, :already_claimed}, state}
                  has_namespace -> {:reply, {:error, :taken}, state}
                  has_user_id -> {:reply, {:error, :already_claimed}, state}
                  true -> {:reply, {:error, :taken}, state}
                end

              {:error, reason} ->
                Logger.error("namespace claim conflict check failed: #{inspect(reason)}")
                {:reply, {:error, :taken}, state}
            end

          {:error, reason} ->
            Logger.error("namespace claim insert failed: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  # ── SQLite mode: owner lookup ────────────────────────────────────────────

  def handle_call({:owner, namespace}, _from, %{sqlite_primary: true} = state) do
    sql = "SELECT user_id FROM namespace_claims WHERE namespace = ?1 LIMIT 1"

    case repo_query(sql, [namespace]) do
      {:ok, %{rows: [[user_id]]}} -> {:reply, %{user_id: user_id}, state}
      _ -> {:reply, nil, state}
    end
  end

  # ── SQLite mode: namespace_for_user_id ─────────────────────────────────────

  def handle_call({:namespace_for_user_id, user_id}, _from, %{sqlite_primary: true} = state) do
    sql = "SELECT namespace FROM namespace_claims WHERE user_id = ?1 LIMIT 1"

    case repo_query(sql, [user_id]) do
      {:ok, %{rows: [[namespace]]}} -> {:reply, namespace, state}
      _ -> {:reply, nil, state}
    end
  end

  # ── clear: SQLite only ────────────────────────────────────────────────────

  def handle_call(:clear, _from, %{sqlite_primary: true} = state) do
    repo_query("DELETE FROM namespace_claims", [])
    {:reply, :ok, state}
  end

  # -- Private helpers --

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
