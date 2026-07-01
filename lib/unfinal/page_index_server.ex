defmodule Unfinal.PageIndexServer do
  @moduledoc "Per-namespace live page index process."

  use GenServer

  require Logger

  alias Unfinal.ContentStore
  alias Unfinal.ObjectIndex
  alias Unfinal.PageIndex

  @initial_retry_ms 25
  @max_retry_ms 1_000

  @doc """
  Returns true if the application is running in Phase 5 SQLite-primary mode.

  In Phase 5 mode, PageIndexServer must not be started (handled by Application
  supervision tree) and must not perform R2 loads if called directly.
  """
  @spec sqlite_primary_mode?() :: boolean()
  def sqlite_primary_mode? do
    Application.get_env(:unfinal, :storage_mode) in [:sqlite_primary_r2_dual_write, :sqlite]
  end

  def start_link(namespace) do
    GenServer.start_link(__MODULE__, namespace,
      name: {:via, Registry, {Unfinal.PageIndexRegistry, namespace}}
    )
  end

  @impl true
  def init(namespace) do
    # In Phase 5 mode, skip R2 loads entirely. The server is kept only for
    # backward compatibility; PageIndex.list/1 uses SQLite directly in Phase 5.
    if sqlite_primary_mode?() do
      {:ok,
       %{
         namespace: namespace,
         entries: [],
         loaded?: true,
         dirty?: false,
         flush_timer: nil,
         flush_ref: nil,
         load_ref: nil,
         load_retry_timer: nil,
         retry_ms: @initial_retry_ms,
         change_id: 0,
         flushing_change_id: nil
       }}
    else
      task =
        Task.Supervisor.async_nolink(Unfinal.PageIndexTaskSupervisor, fn ->
          load(namespace)
        end)

      {:ok,
       %{
         namespace: namespace,
         entries: [],
         loaded?: false,
         dirty?: false,
         flush_timer: nil,
         flush_ref: nil,
         load_ref: task.ref,
         load_retry_timer: nil,
         retry_ms: @initial_retry_ms,
         change_id: 0,
         flushing_change_id: nil
       }}
    end
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, state.entries, state}

  def handle_call({:upsert, path, updated_at}, _from, state) do
    entry = %{path: path, updated_at: DateTime.to_iso8601(updated_at)}

    state =
      state
      |> put_entry(entry)
      |> Map.put(:dirty?, true)
      |> Map.update!(:change_id, &(&1 + 1))
      |> schedule_flush(ContentStore.flush_interval_ms())

    broadcast(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({ref, {:loaded, loaded_entries}}, %{load_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    state =
      loaded_entries
      |> Enum.reduce(state, fn entry, acc -> put_entry_if_absent(acc, entry) end)
      |> Map.merge(%{loaded?: true, load_ref: nil, retry_ms: @initial_retry_ms})

    broadcast(state)
    {:noreply, state}
  end

  def handle_info({ref, {:error, reason}}, %{load_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    Logger.warning("page index load failed for #{state.namespace}: #{inspect(reason)}")
    {:noreply, state |> Map.put(:load_ref, nil) |> retry_load_later()}
  end

  def handle_info({ref, result}, %{flush_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> handle_flush_result(result) |> clear_flushing()}
  end

  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{load_ref: ref} = state) do
    Logger.warning("page index load task crashed for #{state.namespace}: #{inspect(reason)}")
    {:noreply, state |> Map.put(:load_ref, nil) |> retry_load_later()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{flush_ref: ref} = state) do
    Logger.warning("page index flush task crashed for #{state.namespace}: #{inspect(reason)}")
    {:noreply, state |> clear_flushing() |> retry_later()}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:load, state) do
    task =
      Task.Supervisor.async_nolink(Unfinal.PageIndexTaskSupervisor, fn ->
        load(state.namespace)
      end)

    {:noreply, %{state | load_ref: task.ref, load_retry_timer: nil}}
  end

  def handle_info(:flush, state) do
    state = %{state | flush_timer: nil}

    cond do
      not state.dirty? ->
        {:noreply, state}

      not is_nil(state.flush_ref) ->
        {:noreply, schedule_flush(state, ContentStore.flush_interval_ms())}

      not state.loaded? ->
        {:noreply, schedule_flush(state, ContentStore.flush_interval_ms())}

      true ->
        namespace = state.namespace
        entries = state.entries
        change_id = state.change_id

        task =
          Task.Supervisor.async_nolink(Unfinal.PageIndexTaskSupervisor, fn ->
            PageIndex.write(namespace, entries)
          end)

        {:noreply, %{state | flush_ref: task.ref, flushing_change_id: change_id}}
    end
  end

  defp handle_flush_result(state, :ok) do
    state = %{state | retry_ms: @initial_retry_ms}

    if state.change_id == state.flushing_change_id do
      %{state | dirty?: false}
    else
      schedule_flush(state, ContentStore.flush_interval_ms())
    end
  end

  defp handle_flush_result(state, {:error, reason}) do
    Logger.warning("page index flush failed for #{state.namespace}: #{inspect(reason)}")
    retry_later(state)
  end

  defp clear_flushing(state), do: %{state | flush_ref: nil, flushing_change_id: nil}

  defp retry_later(state) do
    retry_ms = min(state.retry_ms * 2, @max_retry_ms)
    %{state | dirty?: true, retry_ms: retry_ms} |> schedule_flush(state.retry_ms)
  end

  defp retry_load_later(%{load_retry_timer: nil} = state) do
    retry_ms = min(state.retry_ms * 2, @max_retry_ms)

    %{
      state
      | retry_ms: retry_ms,
        load_retry_timer: Process.send_after(self(), :load, state.retry_ms)
    }
  end

  defp retry_load_later(state), do: state

  defp schedule_flush(%{flush_timer: nil} = state, delay_ms) do
    %{state | flush_timer: Process.send_after(self(), :flush, delay_ms)}
  end

  defp schedule_flush(state, _delay_ms), do: state

  defp put_entry(state, entry) do
    entries =
      state.entries
      |> Enum.reject(&(&1.path == entry.path))
      |> then(&[entry | &1])
      |> sort_entries()

    %{state | entries: entries}
  end

  defp put_entry_if_absent(state, entry) do
    if Enum.any?(state.entries, &(&1.path == entry.path)),
      do: state,
      else: put_entry(state, entry)
  end

  defp sort_entries(entries), do: Enum.sort_by(entries, & &1.updated_at, :desc)

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Unfinal.PubSub, PageIndex.topic(state.namespace), {
      :page_index_updated,
      state.namespace,
      state.entries
    })
  end

  defp load(namespace) do
    namespace
    |> PageIndex.key()
    |> ObjectIndex.get()
    |> case do
      {:ok, content} -> {:loaded, PageIndex.parse(content)}
      {:error, :not_found} -> {:loaded, []}
      {:error, reason} -> {:error, reason}
    end
  end
end
