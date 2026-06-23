defmodule Unfinal.StaleOnceObjectStore do
  @behaviour Unfinal.ContentStore

  alias Unfinal.ContentStore.Document

  @impl true
  def get(path), do: {:ok, Agent.get(__MODULE__, &Map.get(&1.docs, path, missing(path)))}

  @impl true
  def put(path, content, base_etag, base_revision) do
    Agent.get_and_update(__MODULE__, fn state ->
      current = Map.get(state.docs, path, missing(path))

      cond do
        state.stale_next? ->
          latest = %Document{
            path: path,
            content: "external",
            etag: "external-etag",
            revision: 1,
            write_id: "external"
          }

          {{:stale, latest},
           %{state | stale_next?: false, docs: Map.put(state.docs, path, latest)}}

        current.etag == base_etag and current.revision == base_revision ->
          doc = %Document{
            path: path,
            content: content,
            etag: "etag-#{System.unique_integer([:positive])}",
            revision: base_revision + 1,
            write_id: "write"
          }

          {{:ok, doc}, %{state | docs: Map.put(state.docs, path, doc)}}

        true ->
          {{:stale, current}, state}
      end
    end)
  end

  @impl true
  def clear do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> %{docs: %{}, stale_next?: true} end)
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _pid -> :ok
    end
  end

  def start_link(_opts),
    do: Agent.start_link(fn -> %{docs: %{}, stale_next?: true} end, name: __MODULE__)

  defp missing(path),
    do: %Document{path: path, content: "", etag: nil, revision: 0, write_id: nil}
end
