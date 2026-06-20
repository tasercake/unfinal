defmodule Unfinal.ContentStore do
  @moduledoc """
  Object-store-backed document store with compare-and-set writes.
  """

  use GenServer

  @topic_prefix "document:"
  @key_prefix "documents"

  defmodule Document do
    @moduledoc "Object-store document snapshot."
    @enforce_keys [:path, :content, :etag, :revision]
    defstruct [:path, :content, :etag, :revision]

    @type t :: %__MODULE__{
            path: String.t(),
            content: String.t(),
            etag: String.t() | nil,
            revision: non_neg_integer()
          }
  end

  @type path :: String.t()
  @type content :: String.t()
  @type put_result :: {:ok, Document.t()} | {:stale, Document.t()} | {:error, term()}

  @callback get(String.t()) :: {:ok, Document.t()} | {:error, term()}
  @callback put(String.t(), content(), String.t() | nil, non_neg_integer()) :: put_result()
  @callback clear() :: :ok

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec topic(path()) :: String.t()
  def topic(path), do: @topic_prefix <> Base.url_encode64(normalize_path(path), padding: false)

  @spec get(path()) :: Document.t()
  def get(path), do: GenServer.call(__MODULE__, {:get, normalize_path(path)})

  @spec put(path(), content(), String.t() | nil, non_neg_integer()) :: put_result()
  def put(path, content, base_etag, base_revision)
      when is_binary(content) and (is_binary(base_etag) or is_nil(base_etag)) and
             is_integer(base_revision) and base_revision >= 0 do
    GenServer.call(__MODULE__, {:put, normalize_path(path), content, base_etag, base_revision})
  end

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @spec object_key(path()) :: String.t()
  def object_key(path), do: @key_prefix <> "/" <> sha256(normalize_path(path)) <> ".txt"

  @impl true
  def init(cache), do: {:ok, cache}

  @impl true
  def handle_call({:get, path}, _from, cache) do
    case adapter().get(path) do
      {:ok, doc} -> {:reply, doc, Map.put(cache, path, doc)}
      {:error, reason} -> {:stop, {:object_store_read_failed, reason}, cache}
    end
  end

  @impl true
  def handle_call({:put, path, content, base_etag, base_revision}, _from, cache) do
    case adapter().put(path, content, base_etag, base_revision) do
      {:ok, doc} ->
        Phoenix.PubSub.broadcast(Unfinal.PubSub, topic(path), {
          :content_updated,
          path,
          %{etag: doc.etag, revision: doc.revision}
        })

        {:reply, {:ok, doc}, Map.put(cache, path, doc)}

      {:stale, doc} ->
        {:reply, {:stale, doc}, Map.put(cache, path, doc)}

      {:error, reason} ->
        {:reply, {:error, reason}, cache}
    end
  end

  @impl true
  def handle_call(:clear, _from, _cache) do
    adapter().clear()
    {:reply, :ok, %{}}
  end

  @spec missing(path()) :: Document.t()
  def missing(path), do: %Document{path: path, content: "", etag: nil, revision: 0}

  @spec normalize_path(path()) :: path()
  defp normalize_path(""), do: "/"
  defp normalize_path(path) when is_binary(path), do: path

  defp adapter do
    Application.get_env(:unfinal, :object_store_adapter, Unfinal.S3ObjectStore)
  end

  @spec sha256(path()) :: String.t()
  defp sha256(path), do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
end
