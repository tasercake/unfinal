defmodule Unfinal.LegacyR2Archive do
  @moduledoc """
  Read-only R2 archive wrapper for explicit operator/migration tasks.

  All reads require the `UNFINAL_ALLOW_R2_ARCHIVE_READ` env var to be `"true"`
  or `Application.get_env(:unfinal, :allow_r2_archive_read?, false) == true`.
  No writes are provided — R2 is read-only archive after Phase 6 cutover.

  Not started under the supervision tree.
  """

  alias Unfinal.S3ObjectStore

  @doc """
  Returns true when R2 archive reads are explicitly allowed by operator flag.
  """
  @spec allowed?() :: boolean()
  def allowed? do
    Application.get_env(:unfinal, :allow_r2_archive_read?, false) or
      System.get_env("UNFINAL_ALLOW_R2_ARCHIVE_READ") == "true"
  end

  @doc """
  Read a document from R2 archive. Returns `{:error, :r2_archive_read_disabled}`
  when `allowed?/0` is false.
  """
  @spec get_document(String.t()) :: {:ok, map()} | {:error, term()}
  def get_document(path) when is_binary(path) do
    if allowed?() do
      S3ObjectStore.get(path)
    else
      {:error, :r2_archive_read_disabled}
    end
  end

  @doc """
  Read an object (index, etc.) from R2 archive. Returns
  `{:error, :r2_archive_read_disabled}` when `allowed?/0` is false.
  """
  @spec get_object(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_object(key) when is_binary(key) do
    if allowed?() do
      S3ObjectStore.get_object(key)
    else
      {:error, :r2_archive_read_disabled}
    end
  end
end
