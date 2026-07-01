defmodule Unfinal.BlockingIndexObjectStore do
  @behaviour Unfinal.ContentStore

  def get(path), do: Unfinal.FakeObjectStore.get(path)

  def put(path, content, base_etag, base_revision),
    do: Unfinal.FakeObjectStore.put(path, content, base_etag, base_revision)

  def delete(path, base_etag, base_revision),
    do: Unfinal.FakeObjectStore.delete(path, base_etag, base_revision)

  def clear, do: Unfinal.FakeObjectStore.clear()

  def get_object("indexes/namespaces/" <> _rest = key) do
    Agent.update(__MODULE__, &Map.update!(&1, :get_object_calls, fn calls -> [key | calls] end))
    block(:get_object)
    Unfinal.FakeObjectStore.get_object(key)
  end

  def get_object(key), do: Unfinal.FakeObjectStore.get_object(key)

  def put_object("indexes/namespaces/" <> _rest = key, content) do
    Agent.update(__MODULE__, &Map.update!(&1, :put_object_calls, fn calls -> [key | calls] end))
    send(parent(), {:put_object_started, key})
    block(:put_object)
    Unfinal.FakeObjectStore.put_object(key, content)
  end

  def put_object(key, content), do: Unfinal.FakeObjectStore.put_object(key, content)

  def set_parent(pid), do: Agent.update(__MODULE__, &%{&1 | parent: pid})
  def block_get_object(block?), do: Agent.update(__MODULE__, &%{&1 | block_get_object?: block?})
  def block_put_object(block?), do: Agent.update(__MODULE__, &%{&1 | block_put_object?: block?})
  def reset, do: Agent.update(__MODULE__, fn _state -> initial_state(self()) end)

  def release do
    waiters = Agent.get_and_update(__MODULE__, &{&1.waiters, %{&1 | waiters: []}})
    Enum.each(waiters, fn waiter -> send(waiter, :release_blocking_index_object_store) end)
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _pid -> :ok
    end
  end

  def start_link(_opts) do
    Agent.start(fn -> initial_state(self()) end, name: __MODULE__)
  end

  defp initial_state(parent) do
    %{
      parent: parent,
      waiters: [],
      get_object_calls: [],
      put_object_calls: [],
      block_get_object?: false,
      block_put_object?: false
    }
  end

  defp block(:get_object), do: maybe_block(:block_get_object?)
  defp block(:put_object), do: maybe_block(:block_put_object?)

  defp maybe_block(flag) do
    if Agent.get(__MODULE__, &Map.fetch!(&1, flag)) do
      waiter = self()
      Agent.update(__MODULE__, &Map.update!(&1, :waiters, fn waiters -> [waiter | waiters] end))

      receive do
        :release_blocking_index_object_store -> :ok
      after
        1_000 -> remove_waiter(waiter)
      end
    end
  end

  defp remove_waiter(waiter) do
    Agent.update(
      __MODULE__,
      &Map.update!(&1, :waiters, fn waiters -> List.delete(waiters, waiter) end)
    )
  end

  defp parent, do: Agent.get(__MODULE__, & &1.parent)
end
