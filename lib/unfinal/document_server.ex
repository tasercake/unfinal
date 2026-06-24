defmodule Unfinal.DocumentServer do
  @moduledoc false

  use GenServer

  alias Unfinal.ContentStore
  alias Unfinal.ContentStore.Document

  @type state :: %{
          path: ContentStore.path(),
          document: Document.t(),
          pending_content: ContentStore.content() | nil,
          flush_timer: reference() | nil
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

    {:ok, %{path: path, document: document, pending_content: nil, flush_timer: nil}}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.document, state}

  def handle_call({:put, content, base_etag, base_revision}, _from, state) do
    case write_content(state.path, content, base_etag, base_revision) do
      {:ok, doc} ->
        broadcast(state.path, doc)
        state = after_successful_write(state, doc, content)
        {:reply, {:ok, doc}, state}

      {:stale, doc} ->
        {:reply, {:stale, doc}, %{state | document: doc}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:queue_put, content}, _from, state) do
    state = %{state | pending_content: content} |> schedule_flush()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, %{pending_content: nil} = state) do
    {:noreply, %{state | flush_timer: nil}}
  end

  def handle_info(:flush, state) do
    flushed_content = state.pending_content

    state = %{state | flush_timer: nil}

    case write_content(state.path, flushed_content, state.document.etag, state.document.revision) do
      {:ok, doc} ->
        broadcast(state.path, doc)
        {:noreply, after_successful_write(state, doc, flushed_content)}

      {:stale, doc} ->
        {:noreply, %{state | document: doc} |> schedule_flush()}

      {:error, reason} ->
        require Logger
        Logger.warning("content flush failed for #{state.path}: #{inspect(reason)}")
        {:noreply, schedule_flush(state)}
    end
  end

  defp write_content(path, content, base_etag, base_revision) do
    if blank?(content) do
      ContentStore.adapter().delete(path, base_etag, base_revision)
    else
      ContentStore.adapter().put(path, content, base_etag, base_revision)
    end
  end

  defp blank?(content), do: String.trim(content) == ""

  defp after_successful_write(state, doc, flushed_content) do
    state = %{state | document: doc}

    if state.pending_content == flushed_content do
      cancel_timer(state.flush_timer)
      %{state | pending_content: nil, flush_timer: nil}
    else
      schedule_flush(state)
    end
  end

  defp schedule_flush(%{flush_timer: nil} = state) do
    %{state | flush_timer: Process.send_after(self(), :flush, ContentStore.flush_interval_ms())}
  end

  defp schedule_flush(state), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp broadcast(path, doc) do
    Phoenix.PubSub.broadcast(Unfinal.PubSub, ContentStore.topic(path), {
      :content_updated,
      path,
      %{content: doc.content, etag: doc.etag, revision: doc.revision}
    })
  end
end
