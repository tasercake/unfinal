defmodule Synopticon.ContentStore do
  @moduledoc """
  Tiny in-memory content store with PubSub broadcasts.
  """

  use GenServer

  @topic_prefix "document:"

  @type path :: String.t()
  @type content :: String.t()
  @type documents :: %{path() => content()}

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec topic(path()) :: String.t()
  def topic(path), do: @topic_prefix <> Base.url_encode64(normalize_path(path), padding: false)

  @spec get(path()) :: content()
  def get(path) do
    GenServer.call(__MODULE__, {:get, normalize_path(path)})
  end

  @spec set(path(), content()) :: :ok | {:error, File.posix()}
  def set(path, content) when is_binary(content) do
    path = normalize_path(path)
    GenServer.call(__MODULE__, {:set, path, content})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @spec normalize_path(path()) :: path()
  defp normalize_path(""), do: "/"
  defp normalize_path(path) when is_binary(path), do: path

  @impl true
  def init(documents), do: {:ok, documents}

  @impl true
  def handle_call({:get, path}, _from, documents) do
    case Map.fetch(documents, path) do
      {:ok, content} ->
        {:reply, content, documents}

      :error ->
        content = read_document(path)
        {:reply, content, Map.put(documents, path, content)}
    end
  end

  @impl true
  def handle_call({:set, path, content}, _from, documents) do
    case write_document(path, content) do
      :ok ->
        Phoenix.PubSub.broadcast(
          Synopticon.PubSub,
          topic(path),
          {:content_updated, path, content}
        )

        {:reply, :ok, Map.put(documents, path, content)}

      {:error, reason} ->
        {:reply, {:error, reason}, documents}
    end
  end

  @impl true
  def handle_call(:clear, _from, _documents), do: {:reply, :ok, %{}}

  @spec read_document(path()) :: content()
  defp read_document(path) do
    document_path = document_path(path)

    case File.read(document_path) do
      {:ok, content} -> content
      {:error, _reason} -> ""
    end
  end

  @spec write_document(path(), content()) :: :ok | {:error, File.posix()}
  defp write_document(path, content) do
    document_path = document_path(path)
    documents_dir = Path.dirname(document_path)
    temp_path = document_path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(documents_dir),
         :ok <- File.write(temp_path, content),
         :ok <- File.rename(temp_path, document_path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temp_path)
        error
    end
  end

  @spec document_path(path()) :: String.t()
  defp document_path(path) do
    Path.join([data_dir(), "documents", sha256(path) <> ".txt"])
  end

  @spec data_dir() :: String.t()
  defp data_dir do
    System.get_env("SYNOPTICON_DATA_DIR", "./.data")
  end

  @spec sha256(path()) :: String.t()
  defp sha256(path) do
    :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
  end
end
