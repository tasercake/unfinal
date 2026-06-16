defmodule Synopticon.ContentStore do
  @moduledoc """
  Tiny in-memory content store with PubSub broadcasts.
  """

  use GenServer

  @topic_prefix "document:"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def topic(path), do: @topic_prefix <> Base.url_encode64(normalize_path(path), padding: false)

  def get(path) do
    GenServer.call(__MODULE__, {:get, normalize_path(path)})
  end

  def set(path, content) when is_binary(content) do
    path = normalize_path(path)
    GenServer.call(__MODULE__, {:set, path, content})
  end

  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  defp normalize_path(""), do: "/"
  defp normalize_path(path) when is_binary(path), do: path

  @impl true
  def init(documents), do: {:ok, documents}

  @impl true
  def handle_call({:get, path}, _from, documents) do
    {:reply, Map.get(documents, path, ""), documents}
  end

  @impl true
  def handle_call({:set, path, content}, _from, documents) do
    Phoenix.PubSub.broadcast(Synopticon.PubSub, topic(path), {:content_updated, path, content})
    {:reply, :ok, Map.put(documents, path, content)}
  end

  @impl true
  def handle_call(:clear, _from, _documents), do: {:reply, :ok, %{}}
end
