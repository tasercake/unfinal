defmodule Unfinal.ContentStore do
  @moduledoc """
  Dumb persistence boundary for Unfinal documents.

  This module defines adapter callbacks plus persistence mapping helpers. Live document
  lifecycle, PubSub, debounce, and process ownership live in `Unfinal.Documents` and
  `Unfinal.DocumentServer`.
  """

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
  @callback delete(String.t(), String.t() | nil, non_neg_integer()) :: put_result()
  @callback clear() :: :ok

  @spec object_key(path()) :: String.t()
  def object_key(path), do: @key_prefix <> "/" <> sha256(normalize_path(path)) <> ".txt"

  @spec missing(path()) :: Document.t()
  def missing(path), do: %Document{path: path, content: "", etag: nil, revision: 0, write_id: nil}

  @spec normalize_path(path()) :: path()
  def normalize_path(""), do: "/"
  def normalize_path(path) when is_binary(path), do: path

  @spec adapter() :: module()
  def adapter do
    case Application.get_env(:unfinal, :storage_mode, :r2_primary_sqlite_shadow) do
      :sqlite_primary_r2_dual_write -> Unfinal.SqliteContentStore
      :sqlite -> Unfinal.SqliteContentStore
      _ -> Application.get_env(:unfinal, :object_store_adapter, Unfinal.S3ObjectStore)
    end
  end

  @spec flush_interval_ms() :: pos_integer()
  def flush_interval_ms do
    Application.get_env(:unfinal, :content_store_flush_interval_ms, 500)
  end

  @spec sha256(path()) :: String.t()
  defp sha256(path), do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
end
