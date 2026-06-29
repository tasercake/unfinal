defmodule Unfinal.FlakyIndexLoadObjectStore do
  @behaviour Unfinal.ContentStore

  def get(path), do: Unfinal.FakeObjectStore.get(path)

  def put(path, content, base_etag, base_revision),
    do: Unfinal.FakeObjectStore.put(path, content, base_etag, base_revision)

  def delete(path, base_etag, base_revision),
    do: Unfinal.FakeObjectStore.delete(path, base_etag, base_revision)

  def clear, do: Unfinal.FakeObjectStore.clear()

  def get_object(key) do
    ensure_started()

    Agent.get_and_update(__MODULE__, fn fail_count ->
      if fail_count > 0 do
        {{:error, :temporary}, fail_count - 1}
      else
        {Unfinal.FakeObjectStore.get_object(key), fail_count}
      end
    end)
  end

  def put_object(key, content), do: Unfinal.FakeObjectStore.put_object(key, content)

  def fail_get_objects(count) when is_integer(count) and count >= 0 do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> count end)
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _pid -> :ok
    end
  end

  def start_link(_opts), do: Agent.start(fn -> 0 end, name: __MODULE__)
end
