defmodule Unfinal.ContentStore do
  @moduledoc """
  Object-store-backed document store with compare-and-set writes.
  """

  use GenServer

  @topic_prefix "document:"
  @key_prefix "documents"

  defmodule Document do
    @moduledoc "Object-store document snapshot."
    @enforce_keys [:path, :content, :etag, :revision, :write_id]
    defstruct [:path, :content, :etag, :revision, :write_id]

    @type t :: %__MODULE__{
            path: String.t(),
            content: String.t(),
            etag: String.t() | nil,
            revision: non_neg_integer(),
            write_id: String.t() | nil
          }
  end

  @type path :: String.t()
  @type content :: String.t()
  @type put_result :: {:ok, Document.t()} | {:stale, Document.t()} | {:error, term()}

  @callback get(String.t()) :: {:ok, Document.t()} | {:error, term()}
  @callback put(String.t(), content(), String.t() | nil, non_neg_integer()) :: put_result()
  @callback clear() :: :ok

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec topic(path()) :: String.t()
  def topic(path), do: @topic_prefix <> Base.url_encode64(normalize_path(path), padding: false)

  @spec get(path()) :: Document.t()
  def get(path), do: GenServer.call(__MODULE__, {:get, normalize_path(path)})

  @spec put(path(), content(), String.t() | nil, non_neg_integer()) :: put_result()
  def put(path, content, base_etag, base_revision)
      when is_binary(content) and (is_binary(base_etag) or is_nil(base_etag)) and
             is_integer(base_revision) and base_revision >= 0 do
    GenServer.call(__MODULE__, {:put, normalize_path(path), content, base_etag, base_revision})
  end

  @spec queue_put(path(), content()) :: :ok
  def queue_put(path, content) when is_binary(content) do
    GenServer.call(__MODULE__, {:queue_put, normalize_path(path), content})
  end

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @spec object_key(path()) :: String.t()
  def object_key(path), do: @key_prefix <> "/" <> sha256(normalize_path(path)) <> ".txt"

  @impl true
  def init(cache), do: {:ok, cache}

  @impl true
  def handle_call({:get, path}, _from, state) do
    reply =
      case adapter().get(path) do
        {:ok, doc} -> doc
        {:error, _reason} -> missing(path)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:put, path, content, base_etag, base_revision}, _from, state) do
    reply =
      case adapter().put(path, content, base_etag, base_revision) do
        {:ok, doc} ->
          Phoenix.PubSub.broadcast(Unfinal.PubSub, topic(path), {
            :content_updated,
            path,
            %{content: doc.content, etag: doc.etag, revision: doc.revision}
          })

          {:ok, doc}

        {:stale, doc} ->
          {:stale, doc}

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:queue_put, path, content}, _from, state) do
    entry = Map.get(state, path) || new_entry(path)
    entry = %{entry | pending_content: content} |> schedule_flush(path)

    {:reply, :ok, Map.put(state, path, entry)}
  end

  @impl true
  def handle_call(:clear, _from, cache) do
    Enum.each(cache, fn {_path, entry} -> cancel_timer(entry.timer_ref) end)
    adapter().clear()
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_info({:flush, path}, state) do
    case Map.get(state, path) do
      nil ->
        {:noreply, state}

      %{pending_content: nil} = entry ->
        {:noreply, Map.put(state, path, %{entry | timer_ref: nil})}

      entry ->
        flushed_content = entry.pending_content

        next_entry =
          case adapter().put(
                 path,
                 flushed_content,
                 entry.persisted.etag,
                 entry.persisted.revision
               ) do
            {:ok, doc} ->
              Phoenix.PubSub.broadcast(Unfinal.PubSub, topic(path), {
                :content_updated,
                path,
                %{content: doc.content, etag: doc.etag, revision: doc.revision}
              })

              if entry.pending_content == flushed_content do
                %{entry | persisted: doc, pending_content: nil, timer_ref: nil}
              else
                %{entry | persisted: doc, timer_ref: nil} |> schedule_flush(path)
              end

            {:stale, doc} ->
              %{entry | persisted: doc, timer_ref: nil} |> schedule_flush(path)

            {:error, reason} ->
              require Logger
              Logger.warning("content flush failed for #{path}: #{inspect(reason)}")
              %{entry | timer_ref: nil} |> schedule_flush(path)
          end

        {:noreply, Map.put(state, path, next_entry)}
    end
  end

  @spec missing(path()) :: Document.t()
  def missing(path), do: %Document{path: path, content: "", etag: nil, revision: 0, write_id: nil}

  @spec normalize_path(path()) :: path()
  defp normalize_path(""), do: "/"
  defp normalize_path(path) when is_binary(path), do: path

  defp new_entry(path) do
    persisted =
      case adapter().get(path) do
        {:ok, doc} -> doc
        {:error, _reason} -> missing(path)
      end

    %{persisted: persisted, pending_content: nil, timer_ref: nil}
  end

  defp schedule_flush(%{timer_ref: nil} = entry, path) do
    %{entry | timer_ref: Process.send_after(self(), {:flush, path}, flush_interval_ms())}
  end

  defp schedule_flush(entry, _path), do: entry

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref)

  defp flush_interval_ms do
    Application.get_env(:unfinal, :content_store_flush_interval_ms, 500)
  end

  defp adapter do
    Application.get_env(:unfinal, :object_store_adapter, Unfinal.S3ObjectStore)
  end

  @spec sha256(path()) :: String.t()
  defp sha256(path), do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
end
