defmodule Unfinal.FilesystemObjectStore do
  @moduledoc "Filesystem-backed object store for development and local debugging."

  @behaviour Unfinal.ContentStore

  alias Unfinal.ContentStore
  alias Unfinal.ContentStore.Document

  @default_data_dir "./.data"
  @default_write_delay_ms 200

  @impl true
  def get(path) do
    path
    |> envelope_path()
    |> File.read()
    |> case do
      {:ok, json} -> decode_document(path, json)
      {:error, :enoent} -> {:ok, ContentStore.missing(path)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put(path, content, base_etag, base_revision) do
    with {:ok, current} <- get(path) do
      if current.etag == base_etag and current.revision == base_revision do
        write_document(path, content, base_revision + 1)
      else
        {:stale, current}
      end
    end
  end

  @impl true
  def clear do
    data_dir()
    |> Path.join("documents")
    |> File.rm_rf!()

    :ok
  end

  @spec write_document(String.t(), String.t(), pos_integer()) ::
          {:ok, Document.t()} | {:error, term()}
  defp write_document(path, content, revision) do
    Process.sleep(write_delay_ms())

    doc = %Document{
      path: path,
      content: content,
      etag: etag(content, revision),
      revision: revision
    }

    file_path = envelope_path(path)

    with :ok <- File.mkdir_p(Path.dirname(file_path)),
         {:ok, json} <- encode_document(doc),
         :ok <- File.write(file_path, json) do
      {:ok, doc}
    end
  end

  @spec decode_document(String.t(), String.t()) :: {:ok, Document.t()} | {:error, term()}
  defp decode_document(path, json) do
    with {:ok, envelope} <- Jason.decode(json),
         {:ok, content} <- fetch_string(envelope, "content"),
         {:ok, etag} <- fetch_string(envelope, "etag"),
         {:ok, revision} <- fetch_revision(envelope) do
      {:ok, %Document{path: path, content: content, etag: etag, revision: revision}}
    end
  end

  @spec encode_document(Document.t()) :: {:ok, String.t()} | {:error, term()}
  defp encode_document(%Document{} = doc) do
    Jason.encode(%{"content" => doc.content, "etag" => doc.etag, "revision" => doc.revision})
  end

  @spec fetch_string(map(), String.t()) ::
          {:ok, String.t()} | {:error, {:invalid_envelope, String.t()}}
  defp fetch_string(envelope, key) do
    case Map.fetch(envelope, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_envelope, key}}
    end
  end

  @spec fetch_revision(map()) ::
          {:ok, non_neg_integer()} | {:error, {:invalid_envelope, String.t()}}
  defp fetch_revision(envelope) do
    case Map.fetch(envelope, "revision") do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_envelope, "revision"}}
    end
  end

  @spec envelope_path(String.t()) :: Path.t()
  defp envelope_path(path) do
    object_path = ContentStore.object_key(path) |> Path.rootname() |> Kernel.<>(".json")
    Path.join(data_dir(), object_path)
  end

  @spec data_dir() :: Path.t()
  defp data_dir do
    config()
    |> Keyword.get(:data_dir)
    |> case do
      nil -> System.get_env("UNFINAL_DATA_DIR", @default_data_dir)
      value when is_binary(value) -> value
    end
  end

  @spec write_delay_ms() :: non_neg_integer()
  defp write_delay_ms do
    config()
    |> Keyword.get(:write_delay_ms, @default_write_delay_ms)
    |> case do
      value when is_integer(value) and value >= 0 -> value
    end
  end

  @spec config() :: keyword()
  defp config, do: Application.get_env(:unfinal, :filesystem_object_store, [])

  @spec etag(String.t(), pos_integer()) :: String.t()
  defp etag(content, revision) do
    :crypto.hash(:sha256, [content, Integer.to_string(revision), unique()])
    |> Base.encode16(case: :lower)
  end

  @spec unique() :: String.t()
  defp unique, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
end
