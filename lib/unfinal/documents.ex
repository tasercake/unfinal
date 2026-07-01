defmodule Unfinal.Documents do
  @moduledoc """
  Public live-document facade.

  Starts one `Unfinal.DocumentServer` per document path on this BEAM node. This module owns
  live document lifecycle, debounced persistence, and PubSub topics; persistence remains under
  `Unfinal.ContentStore` adapters.
  """

  alias Unfinal.ContentStore
  alias Unfinal.ContentStore.Document

  @topic_prefix "document:"

  @type path :: ContentStore.path()
  @type content :: ContentStore.content()

  @spec topic(path()) :: String.t()
  def topic(path),
    do: @topic_prefix <> Base.url_encode64(ContentStore.normalize_path(path), padding: false)

  @spec get(path()) :: Document.t()
  def get(path), do: path |> ContentStore.normalize_path() |> server_call(:get)

  @spec queue_put(path(), content()) :: :ok
  def queue_put(path, content) when is_binary(content) do
    path |> ContentStore.normalize_path() |> server_call({:queue_put, content})
  end

  @doc """
  Permanently delete a document. Requires ownership of the document's namespace.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec delete(path(), String.t()) :: :ok | {:error, term()}
  def delete(path, owner_email) when is_binary(path) and is_binary(owner_email) do
    normalized = ContentStore.normalize_path(path)

    with {:ok, namespace} <- extract_namespace(normalized),
         true <- namespace_owned_by?(namespace, owner_email),
         false <- namespace_root?(normalized) do
      case delete_from_store(normalized) do
        :ok ->
          stop_server(normalized)
          wait_for_server_stopped(normalized)
          broadcast_deletion(normalized, namespace)

        {:error, reason} ->
          {:error, reason}
      end
    else
      true -> {:error, :cannot_delete_root}
      false -> {:error, :not_authorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec clear() :: :ok
  def clear do
    Unfinal.DocumentSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> {pid, Process.monitor(pid)} end)
    |> Enum.each(fn {pid, monitor_ref} ->
      _result = DynamicSupervisor.terminate_child(Unfinal.DocumentSupervisor, pid)
      wait_for_down(monitor_ref)
      wait_for_unregistered(pid)
    end)

    ContentStore.adapter().clear()
  end

  # -- Private helpers for delete --

  defp extract_namespace("/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [namespace] when namespace != "" -> {:ok, namespace}
      [namespace, _rel] when namespace != "" -> {:ok, namespace}
      _ -> {:error, :invalid_path}
    end
  end

  defp extract_namespace(_), do: {:error, :invalid_path}

  defp namespace_owned_by?(namespace, email) do
    case Unfinal.NamespaceStore.owner(namespace) do
      %{email: ^email} -> true
      _ -> false
    end
  end

  defp namespace_root?(path) do
    case extract_namespace(path) do
      {:ok, ns} -> path == "/" <> ns
      _ -> false
    end
  end

  defp delete_from_store(path) do
    case ContentStore.adapter().get(path) do
      {:ok, doc} ->
        case ContentStore.adapter().delete(path, doc.etag, doc.revision) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_server(path) do
    case Registry.lookup(Unfinal.DocumentRegistry, path) do
      [{pid, _}] ->
        try do
          DynamicSupervisor.terminate_child(Unfinal.DocumentSupervisor, pid)
        rescue
          ArgumentError -> :ok
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  defp wait_for_server_stopped(path, attempts \\ 100)
  defp wait_for_server_stopped(_path, 0), do: :ok

  defp wait_for_server_stopped(path, attempts) do
    case Registry.lookup(Unfinal.DocumentRegistry, path) do
      [] -> :ok
      _ -> Process.sleep(10) && wait_for_server_stopped(path, attempts - 1)
    end
  end

  defp broadcast_deletion(storage_path, namespace) do
    Phoenix.PubSub.broadcast(Unfinal.PubSub, topic(storage_path), {
      :content_updated,
      storage_path,
      %{content: "", etag: nil, revision: 0}
    })

    entries = Unfinal.SqliteDocuments.list_namespace(namespace)

    Phoenix.PubSub.broadcast(Unfinal.PubSub, Unfinal.PageIndex.topic(namespace), {
      :page_index_updated,
      namespace,
      entries
    })

    :ok
  end

  defp server_call(path, message) do
    {:ok, pid} = server(path)
    GenServer.call(pid, message)
  end

  defp server(path) do
    case Registry.lookup(Unfinal.DocumentRegistry, path) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Unfinal.DocumentSupervisor,
               {Unfinal.DocumentServer, path}
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

  defp wait_for_unregistered(pid, attempts \\ 50)
  defp wait_for_unregistered(_pid, 0), do: :ok

  defp wait_for_unregistered(pid, attempts) do
    case Registry.keys(Unfinal.DocumentRegistry, pid) do
      [] ->
        :ok

      _keys ->
        Process.sleep(10)
        wait_for_unregistered(pid, attempts - 1)
    end
  end
end
