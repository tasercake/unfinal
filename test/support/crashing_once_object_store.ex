defmodule Unfinal.CrashingOnceObjectStore do
  @behaviour Unfinal.ContentStore

  @impl true
  def get(path), do: Unfinal.FakeObjectStore.get(path)

  @impl true
  def put(path, content, base_etag, base_revision) do
    if crash_next?() do
      raise "crashing once during put"
    else
      Unfinal.FakeObjectStore.put(path, content, base_etag, base_revision)
    end
  end

  def get_object(key), do: Unfinal.FakeObjectStore.get_object(key)
  def put_object(key, content), do: Unfinal.FakeObjectStore.put_object(key, content)

  @impl true
  def delete(path, base_etag, base_revision) do
    if crash_next?() do
      raise "crashing once during delete"
    else
      Unfinal.FakeObjectStore.delete(path, base_etag, base_revision)
    end
  end

  @impl true
  def clear do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> false end)
    Unfinal.FakeObjectStore.clear()
  end

  def crash_next_put do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> true end)
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _pid -> :ok
    end
  end

  def start_link(_opts), do: Agent.start(fn -> false end, name: __MODULE__)

  defp crash_next? do
    ensure_started()
    Agent.get_and_update(__MODULE__, fn crash? -> {crash?, false} end)
  end
end
