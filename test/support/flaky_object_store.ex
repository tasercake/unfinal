defmodule Unfinal.FlakyObjectStore do
  @behaviour Unfinal.ContentStore

  alias Unfinal.ContentStore.Document

  @impl true
  def get(path), do: {:ok, Agent.get(__MODULE__, &Map.get(&1.docs, path, missing(path)))}

  @impl true
  def put(path, content, base_etag, base_revision) do
    Agent.get_and_update(__MODULE__, fn state ->
      if state.fail_next? do
        {{:error, :temporary}, %{state | fail_next?: false}}
      else
        current = Map.get(state.docs, path, missing(path))

        if current.etag == base_etag and current.revision == base_revision do
          doc = %Document{
            path: path,
            content: content,
            etag: "etag-#{System.unique_integer([:positive])}",
            revision: base_revision + 1,
            write_id: "write"
          }

          {{:ok, doc}, %{state | docs: Map.put(state.docs, path, doc)}}
        else
          {{:stale, current}, state}
        end
      end
    end)
  end

  @impl true
  def clear do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> %{docs: %{}, fail_next?: false} end)
  end

  def fail_next_put do
    ensure_started()
    Agent.update(__MODULE__, &%{&1 | fail_next?: true})
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _pid -> :ok
    end
  end

  def start_link(_opts),
    do: Agent.start_link(fn -> %{docs: %{}, fail_next?: false} end, name: __MODULE__)

  defp missing(path),
    do: %Document{path: path, content: "", etag: nil, revision: 0, write_id: nil}
end
