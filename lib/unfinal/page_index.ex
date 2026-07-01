defmodule Unfinal.PageIndex do
  @moduledoc "Live namespace page index facade."

  alias Unfinal.DocumentPath
  alias Unfinal.ObjectIndex

  @topic_prefix "page_index:"

  @type entry :: %{path: String.t(), updated_at: String.t()}

  @spec topic(String.t()) :: String.t()
  def topic(namespace), do: @topic_prefix <> Base.url_encode64(namespace, padding: false)

  @spec list(String.t()) :: [entry()]
  def list(namespace) when is_binary(namespace) do
    if valid_namespace?(namespace) do
      case Application.get_env(:unfinal, :storage_mode, :r2) do
        :sqlite ->
          Unfinal.SqliteDocuments.list_namespace(namespace)

        _ ->
          server_call(namespace, :list)
      end
    else
      []
    end
  end

  @spec upsert(String.t(), String.t(), DateTime.t()) :: :ok | {:error, term()}
  def upsert(namespace, path, %DateTime{} = updated_at)
      when is_binary(namespace) and is_binary(path) do
    if valid_namespace?(namespace) and DocumentPath.valid_relative_path?(path) do
      case Application.get_env(:unfinal, :storage_mode, :r2) do
        :sqlite ->
          updated_at_iso = DateTime.to_iso8601(updated_at)

          case Unfinal.SqliteDocuments.touch_page(namespace, path, updated_at_iso) do
            :ok ->
              entries = Unfinal.SqliteDocuments.list_namespace(namespace)
              Unfinal.R2Mirror.mirror_page_index_async(namespace, entries)

              Phoenix.PubSub.broadcast(Unfinal.PubSub, topic(namespace), {
                :page_index_updated,
                namespace,
                entries
              })

              :ok

            {:error, reason} ->
              {:error, reason}
          end

        _ ->
          server_call(namespace, {:upsert, path, updated_at})
      end
    else
      {:error, :invalid}
    end
  end

  @spec clear() :: :ok
  def clear do
    Unfinal.PageIndexSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> {pid, Process.monitor(pid)} end)
    |> Enum.each(fn {pid, monitor_ref} ->
      _result = DynamicSupervisor.terminate_child(Unfinal.PageIndexSupervisor, pid)
      wait_for_down(monitor_ref)
    end)

    :ok
  end

  @spec parse(String.t()) :: [entry()]
  def parse(content) do
    content
    |> String.split(["\r\n", "\n", "\r"], trim: true)
    |> Enum.flat_map(fn line ->
      with {:ok, %{"path" => path, "updated_at" => updated_at}} <- Jason.decode(line),
           true <- DocumentPath.valid_relative_path?(path),
           {:ok, _dt, 0} <- DateTime.from_iso8601(updated_at) do
        [%{path: path, updated_at: updated_at}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  @spec write(String.t(), [entry()]) :: :ok | {:error, term()}
  def write(namespace, entries) do
    content =
      entries
      |> Enum.sort_by(& &1.updated_at, :desc)
      |> Enum.map_join("", fn entry ->
        Jason.encode!(%{path: entry.path, updated_at: entry.updated_at}) <> "\n"
      end)

    ObjectIndex.put(key(namespace), content)
  end

  @spec key(String.t()) :: String.t()
  def key(namespace), do: "indexes/namespaces/#{namespace}.ndjson"

  defp valid_namespace?(namespace), do: DocumentPath.valid_segment?(namespace)

  defp server_call(namespace, message) do
    {:ok, pid} = server(namespace)
    GenServer.call(pid, message)
  end

  defp server(namespace) do
    case Registry.lookup(Unfinal.PageIndexRegistry, namespace) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Unfinal.PageIndexSupervisor,
               {Unfinal.PageIndexServer, namespace}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  defp wait_for_down(monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, _pid, _reason} -> :ok
    after
      5_000 -> :ok
    end
  end
end
