defmodule Unfinal.BlockingObjectStore do
  @behaviour Unfinal.ContentStore

  @impl true
  def get(path), do: Unfinal.FakeObjectStore.get(path)

  @impl true
  def put("/slow", content, base_etag, base_revision) do
    waiter = self()
    Agent.update(__MODULE__, fn state -> %{state | waiter: waiter} end)
    send(parent(), :slow_put_started)

    receive do
      :release_slow_put -> :ok
    after
      1_000 -> :ok
    end

    Agent.update(__MODULE__, fn state -> %{state | waiter: nil} end)
    Unfinal.FakeObjectStore.put("/slow", content, base_etag, base_revision)
  end

  def put(path, content, base_etag, base_revision) do
    Unfinal.FakeObjectStore.put(path, content, base_etag, base_revision)
  end

  def get_object(key), do: Unfinal.FakeObjectStore.get_object(key)

  def put_object(key, content), do: Unfinal.FakeObjectStore.put_object(key, content)

  @impl true
  def delete(path, base_etag, base_revision) do
    Unfinal.FakeObjectStore.delete(path, base_etag, base_revision)
  end

  @impl true
  def clear, do: Unfinal.FakeObjectStore.clear()

  def set_parent(pid) when is_pid(pid),
    do: Agent.update(__MODULE__, fn state -> %{state | parent: pid} end)

  def release_slow_put do
    case Agent.get(__MODULE__, & &1.waiter) do
      nil -> :ok
      pid -> send(pid, :release_slow_put)
    end
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _pid -> :ok
    end
  end

  def start_link(_opts),
    do: Agent.start(fn -> %{parent: self(), waiter: nil} end, name: __MODULE__)

  defp parent, do: Agent.get(__MODULE__, & &1.parent)
end
