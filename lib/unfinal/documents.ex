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

  @spec put(path(), content(), String.t() | nil, non_neg_integer()) :: ContentStore.put_result()
  def put(path, content, base_etag, base_revision)
      when is_binary(content) and (is_binary(base_etag) or is_nil(base_etag)) and
             is_integer(base_revision) and base_revision >= 0 do
    path
    |> ContentStore.normalize_path()
    |> server_call({:put, content, base_etag, base_revision})
  end

  @spec queue_put(path(), content()) :: :ok
  def queue_put(path, content) when is_binary(content) do
    path |> ContentStore.normalize_path() |> server_call({:queue_put, content})
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
