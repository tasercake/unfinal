defmodule Unfinal.NamespaceStore do
  @moduledoc """
  Namespace ownership store. In SQLite-primary mode, SQLite is primary.
  In R2 mode, backed by R2 indexes/namespaces.txt.
  """

  use GenServer
  require Logger

  alias Unfinal.SQLiteShadow

  @type namespace :: String.t()
  @type email :: String.t()
  @type owner :: %{email: email()}
  @index_key "indexes/namespaces.txt"

  @type state :: %{
          sqlite_primary: boolean(),
          # Only used in R2 mode:
          r2_state: %{namespace() => owner()}
        }

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec valid_namespace?(term()) :: boolean()
  def valid_namespace?(namespace), do: Unfinal.DocumentPath.valid_segment?(namespace)

  @spec claim(namespace(), map()) :: :ok | {:error, :invalid | :taken | :already_claimed}
  def claim(namespace, %{"email" => email}) when is_binary(email) do
    GenServer.call(__MODULE__, {:claim, namespace, email})
  end

  def claim(_namespace, _user), do: {:error, :invalid}

  @spec owner(namespace()) :: owner() | nil
  def owner(namespace), do: GenServer.call(__MODULE__, {:owner, namespace})

  @spec taken?(namespace()) :: boolean()
  def taken?(namespace), do: not is_nil(owner(namespace))

  @spec namespace_for_email(email()) :: namespace() | nil
  def namespace_for_email(email) when is_binary(email),
    do: GenServer.call(__MODULE__, {:namespace_for_email, email})

  def namespace_for_email(_email), do: nil

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  # -- GenServer callbacks --

  @impl true
  def init(_state) do
    sqlite_primary = Application.get_env(:unfinal, :storage_mode) == :sqlite

    {:ok, %{sqlite_primary: sqlite_primary, r2_state: %{}}}
  end

  # ── SQLite primary claim ───────────────────────────────────────────────────

  @impl true
  def handle_call({:claim, namespace, email}, _from, %{sqlite_primary: true} = state) do
    cond do
      not valid_namespace?(namespace) ->
        {:reply, {:error, :invalid}, state}

      true ->
        now = DateTime.to_iso8601(DateTime.utc_now())
        sql = "INSERT INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)"

        case repo_query(sql, [namespace, email, now]) do
          {:ok, %{num_rows: 1}} ->
            mirror_namespace_index_async()
            {:reply, :ok, state}

          {:ok, %{num_rows: 0}} ->
            # Conflict — determine if taken or already_claimed
            check_sql =
              "SELECT namespace, email FROM namespace_claims WHERE namespace = ?1 OR email = ?2 LIMIT 2"

            case repo_query(check_sql, [namespace, email]) do
              {:ok, %{rows: rows}} ->
                has_namespace = Enum.any?(rows, fn [ns, _] -> ns == namespace end)
                has_email = Enum.any?(rows, fn [_, em] -> em == email end)

                cond do
                  has_namespace and has_email -> {:reply, {:error, :already_claimed}, state}
                  has_namespace -> {:reply, {:error, :taken}, state}
                  has_email -> {:reply, {:error, :already_claimed}, state}
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

  # ── R2 mode: original claim logic ───────────────────────────────────────

  def handle_call({:claim, namespace, email}, _from, %{sqlite_primary: false} = state) do
    cond do
      not valid_namespace?(namespace) ->
        {:reply, {:error, :invalid}, state}

      namespace_for_email(state.r2_state, email) ->
        {:reply, {:error, :already_claimed}, state}

      Map.has_key?(state.r2_state, namespace) ->
        {:reply, {:error, :taken}, state}

      true ->
        new_r2_state = Map.put(state.r2_state, namespace, %{email: email})
        :ok = write_all_r2(new_r2_state)

        case SQLiteShadow.insert_namespace_claim(namespace, email, DateTime.utc_now()) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "sqlite shadow namespace claim insert failed for #{namespace}: #{inspect(reason)}"
            )
        end

        {:reply, :ok, %{state | r2_state: new_r2_state}}
    end
  end

  # ── SQLite mode: owner lookup ────────────────────────────────────────────

  def handle_call({:owner, namespace}, _from, %{sqlite_primary: true} = state) do
    sql = "SELECT email FROM namespace_claims WHERE namespace = ?1 LIMIT 1"

    case repo_query(sql, [namespace]) do
      {:ok, %{rows: [[email]]}} -> {:reply, %{email: email}, state}
      _ -> {:reply, nil, state}
    end
  end

  # ── R2 mode: owner lookup ────────────────────────────────────────────────

  def handle_call({:owner, namespace}, _from, %{sqlite_primary: false} = state) do
    r2_state = reload_r2()
    {:reply, Map.get(r2_state, namespace), %{state | r2_state: r2_state}}
  end

  # ── SQLite mode: namespace_for_email ─────────────────────────────────────

  def handle_call({:namespace_for_email, email}, _from, %{sqlite_primary: true} = state) do
    sql = "SELECT namespace FROM namespace_claims WHERE email = ?1 LIMIT 1"

    case repo_query(sql, [email]) do
      {:ok, %{rows: [[namespace]]}} -> {:reply, namespace, state}
      _ -> {:reply, nil, state}
    end
  end

  # ── R2 mode: namespace_for_email ─────────────────────────────────────────

  def handle_call({:namespace_for_email, email}, _from, %{sqlite_primary: false} = state) do
    r2_state = reload_r2()

    result =
      Enum.find_value(r2_state, fn {ns, owner} ->
        if owner.email == email, do: ns
      end)

    {:reply, result, %{state | r2_state: r2_state}}
  end

  # ── clear: both modes ────────────────────────────────────────────────────

  def handle_call(:clear, _from, %{sqlite_primary: true} = state) do
    repo_query("DELETE FROM namespace_claims", [])
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, %{sqlite_primary: false} = state) do
    :ok = write_all_r2(%{})
    {:reply, :ok, %{state | r2_state: %{}}}
  end

  # -- Private R2 helpers (only used in R2 mode) --

  defp reload_r2 do
    case Unfinal.ObjectIndex.get(@index_key) do
      {:ok, content} -> parse_r2(content)
      {:error, _reason} -> %{}
    end
  end

  defp parse_r2(content) do
    content
    |> String.split(["\r\n", "\n", "\r"], trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "\t", parts: 3) do
        [namespace, email] -> Map.put(acc, namespace, %{email: email})
        _parts -> acc
      end
    end)
  end

  defp write_all_r2(state_map) do
    content =
      state_map
      |> Enum.sort_by(fn {namespace, _owner} -> namespace end)
      |> Enum.map_join("", fn {namespace, owner} ->
        "#{namespace}\t#{owner.email}\n"
      end)

    :ok = Unfinal.ObjectIndex.put(@index_key, content)
  end

  defp mirror_namespace_index_async do
    # Read current SQLite claims and mirror to R2
    case repo_query("SELECT namespace, email FROM namespace_claims ORDER BY namespace", []) do
      {:ok, %{rows: rows}} ->
        claims = Map.new(rows, fn [ns, email] -> {ns, %{email: email}} end)
        Unfinal.R2Mirror.mirror_namespace_index_async(claims)

      {:error, reason} ->
        Logger.warning("failed to read namespace claims for R2 mirror: #{inspect(reason)}")
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

  # -- Private helper used in both R2-mode claim and R2-mode namespace_for_email --

  defp namespace_for_email(state, email) when is_map(state) do
    Enum.find_value(state, fn {namespace, owner} ->
      if owner.email == email, do: namespace
    end)
  end
end
