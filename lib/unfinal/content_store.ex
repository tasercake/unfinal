defmodule Unfinal.ContentStore do
  @moduledoc """
  Object-store-backed document store facade.
  """

  @topic_prefix "document:"
  @key_prefix "documents"

  defmodule Document do
    @moduledoc "Object-store document snapshot."
    @enforce_keys [:path, :content, :etag, :revision, :write_id]
    defstruct [:path, :content, :etag, :revision, :write_id]

    @type t :: %__MODULE__{
            path: String.t(),
            content: String.t(),
            etag: String.t() | nil,
            revision: non_neg_integer(),
            write_id: String.t() | nil
          }
  end

  @type path :: String.t()
  @type content :: String.t()
  @type put_result :: {:ok, Document.t()} | {:stale, Document.t()} | {:error, term()}

  @callback get(String.t()) :: {:ok, Document.t()} | {:error, term()}
  @callback put(String.t(), content(), String.t() | nil, non_neg_integer()) :: put_result()
  @callback delete(String.t(), String.t() | nil, non_neg_integer()) :: put_result()
  @callback clear() :: :ok

  @spec topic(path()) :: String.t()
  def topic(path), do: @topic_prefix <> Base.url_encode64(normalize_path(path), padding: false)

  @spec get(path()) :: Document.t()
  def get(path), do: path |> normalize_path() |> server_call(:get)

  @spec put(path(), content(), String.t() | nil, non_neg_integer()) :: put_result()
  def put(path, content, base_etag, base_revision)
      when is_binary(content) and (is_binary(base_etag) or is_nil(base_etag)) and
             is_integer(base_revision) and base_revision >= 0 do
    path = normalize_path(path)
    server_call(path, {:put, content, base_etag, base_revision})
  end

  @spec queue_put(path(), content()) :: :ok
  def queue_put(path, content) when is_binary(content) do
    path |> normalize_path() |> server_call({:queue_put, content})
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

    adapter().clear()
  end

  @spec object_key(path()) :: String.t()
  def object_key(path), do: @key_prefix <> "/" <> sha256(normalize_path(path)) <> ".txt"

  @spec missing(path()) :: Document.t()
  def missing(path), do: %Document{path: path, content: "", etag: nil, revision: 0, write_id: nil}

  @spec normalize_path(path()) :: path()
  def normalize_path(""), do: "/"
  def normalize_path(path) when is_binary(path), do: path

  @spec adapter() :: module()
  def adapter, do: Application.get_env(:unfinal, :object_store_adapter, Unfinal.S3ObjectStore)

  @spec flush_interval_ms() :: pos_integer()
  def flush_interval_ms do
    Application.get_env(:unfinal, :content_store_flush_interval_ms, 500)
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

  @spec wait_for_down(reference()) :: :ok
  defp wait_for_down(monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, _pid, _reason} -> :ok
    after
      5_000 -> :ok
    end
  end

  @spec wait_for_unregistered(pid(), non_neg_integer()) :: :ok
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

  @spec sha256(path()) :: String.t()
  defp sha256(path), do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
end
