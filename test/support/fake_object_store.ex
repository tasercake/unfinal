defmodule Unfinal.FakeObjectStore do
  @behaviour Unfinal.ContentStore

  alias Unfinal.ContentStore.Document

  @impl true
  def get(path) do
    {:ok, Agent.get(__MODULE__, &Map.get(&1, path, missing(path)))}
  end

  @impl true
  def put(path, content, base_etag, base_revision) do
    Agent.get_and_update(__MODULE__, fn state ->
      current = Map.get(state, path, missing(path))

      if current.etag == base_etag and current.revision == base_revision do
        doc = %Document{
          path: path,
          content: content,
          etag: "etag-#{System.unique_integer([:positive])}",
          revision: base_revision + 1
        }

        {{:ok, doc}, Map.put(state, path, doc)}
      else
        {{:stale, current}, state}
      end
    end)
  end

  @impl true
  def clear do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> %{} end)
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _pid -> :ok
    end
  end

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  defp missing(path), do: %Document{path: path, content: "", etag: nil, revision: 0}
end
