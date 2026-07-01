defmodule Unfinal.DocumentServer do
  @moduledoc """
  Per-document live state process.

  Single-BEAM-node ownership: Registry/DynamicSupervisor ensure one process per path on this
  node only. Writes ACK after memory update, then flush durably via debounced async tasks.
  """

  use GenServer

  require Logger

  alias Unfinal.ContentStore
  alias Unfinal.ContentStore.Document
  alias Unfinal.Documents
  alias Unfinal.PageIndex
  alias Unfinal.SQLiteShadow

  @initial_retry_ms 25
  @max_retry_ms 1_000

  @type state :: %{
          path: ContentStore.path(),
          document: Document.t(),
          version: non_neg_integer(),
          dirty_version: non_neg_integer() | nil,
          dirty_content: ContentStore.content() | nil,
          flush_timer: reference() | nil,
          flush_ref: reference() | nil,
          flushing_version: non_neg_integer() | nil,
          flushing_content: ContentStore.content() | nil,
          retry_ms: pos_integer()
        }

  @spec start_link(ContentStore.path()) :: GenServer.on_start()
  def start_link(path) do
    GenServer.start_link(__MODULE__, path,
      name: {:via, Registry, {Unfinal.DocumentRegistry, path}}
    )
  end

  @impl true
  def init(path) do
    document =
      case ContentStore.adapter().get(path) do
        {:ok, doc} -> doc
        {:error, _reason} -> ContentStore.missing(path)
      end

    {:ok,
     %{
       path: path,
       document: document,
       version: 0,
       dirty_version: nil,
       dirty_content: nil,
       flush_timer: nil,
       flush_ref: nil,
       flushing_version: nil,
       flushing_content: nil,
       retry_ms: @initial_retry_ms
     }}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.document, state}

  def handle_call({:queue_put, content}, _from, state) do
    version = state.version + 1

    %Document{} = current_document = state.document
    document = %Document{current_document | content: content}

    state =
      %{
        state
        | document: document,
          version: version,
          dirty_version: version,
          dirty_content: content
      }
      |> schedule_flush(ContentStore.flush_interval_ms())

    upsert_page_index(state.path)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = %{state | flush_timer: nil}

    cond do
      is_nil(state.dirty_version) ->
        {:noreply, state}

      not is_nil(state.flush_ref) ->
        {:noreply, schedule_flush(state, ContentStore.flush_interval_ms())}

      true ->
        content = state.dirty_content
        version = state.dirty_version
        base_etag = state.document.etag
        base_revision = state.document.revision
        path = state.path

        task =
          Task.Supervisor.async_nolink(Unfinal.DocumentTaskSupervisor, fn ->
            write_content(path, content, base_etag, base_revision)
          end)

        {:noreply,
         %{
           state
           | flush_ref: task.ref,
             flushing_version: version,
             flushing_content: content
         }}
    end
  end

  def handle_info({ref, result}, %{flush_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> handle_flush_result(result) |> clear_flushing()}
  end

  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{flush_ref: ref} = state) do
    Logger.warning("content flush task crashed for #{state.path}: #{inspect(reason)}")
    {:noreply, retry_later(clear_flushing(state))}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp handle_flush_result(state, {:ok, doc}) do
    state = %{
      state
      | document: merge_durable_metadata(state.document, doc),
        retry_ms: @initial_retry_ms
    }

    state =
      if state.dirty_version == state.flushing_version and
           state.dirty_content == state.flushing_content do
        %{state | dirty_version: nil, dirty_content: nil}
      else
        state
      end

    broadcast(state.path, state.document)

    if is_nil(state.dirty_version) do
      state
    else
      schedule_flush(state, ContentStore.flush_interval_ms())
    end
  end

  defp handle_flush_result(state, {:stale, doc}) do
    %{state | document: merge_durable_metadata(state.document, doc), retry_ms: @initial_retry_ms}
    |> schedule_flush(ContentStore.flush_interval_ms())
  end

  defp handle_flush_result(state, {:error, reason}) do
    Logger.warning("content flush failed for #{state.path}: #{inspect(reason)}")
    retry_later(state)
  end

  defp clear_flushing(state) do
    %{state | flush_ref: nil, flushing_version: nil, flushing_content: nil}
  end

  defp retry_later(state) do
    retry_ms = min(state.retry_ms * 2, @max_retry_ms)
    %{state | retry_ms: retry_ms} |> schedule_flush(state.retry_ms)
  end

  defp write_content(path, content, base_etag, base_revision) do
    case ContentStore.adapter().put(path, content, base_etag, base_revision) do
      {:ok, %Document{} = doc} ->
        # Skip shadow write in SQLite-primary mode (already written by adapter)
        unless Application.get_env(:unfinal, :storage_mode) == :sqlite_primary_r2_dual_write do
          case SQLiteShadow.upsert_document(doc, DateTime.utc_now()) do
            :ok ->
              :ok

            :ignored ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "sqlite shadow document upsert failed for #{path}: #{inspect(reason)}"
              )
          end
        end

        {:ok, doc}

      other ->
        other
    end
  end

  defp merge_durable_metadata(%Document{} = visible_doc, %Document{} = durable_doc) do
    %Document{
      visible_doc
      | etag: durable_doc.etag,
        revision: durable_doc.revision,
        write_id: durable_doc.write_id
    }
  end

  defp schedule_flush(%{flush_timer: nil} = state, delay_ms) do
    %{state | flush_timer: Process.send_after(self(), :flush, delay_ms)}
  end

  defp schedule_flush(state, _delay_ms), do: state

  defp upsert_page_index("/" <> path) do
    case String.split(path, "/", parts: 2) do
      [namespace] ->
        PageIndex.upsert(namespace, "/", DateTime.utc_now())

      [namespace, relative] when relative != "" ->
        PageIndex.upsert(namespace, "/" <> relative, DateTime.utc_now())

      _other ->
        :ok
    end
  end

  defp upsert_page_index(_path), do: :ok

  defp broadcast(path, doc) do
    Phoenix.PubSub.broadcast(Unfinal.PubSub, Documents.topic(path), {
      :content_updated,
      path,
      %{content: doc.content, etag: doc.etag, revision: doc.revision}
    })
  end
end
