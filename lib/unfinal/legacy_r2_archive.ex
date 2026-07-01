defmodule Unfinal.LegacyR2Archive do
  @moduledoc """
  Read-only R2 archive wrapper for explicit operator/migration tasks.

  All reads require the `UNFINAL_ALLOW_R2_ARCHIVE_READ` env var to be `"true"`
  or `Application.get_env(:unfinal, :allow_r2_archive_read?, false) == true`.
  No writes are provided — R2 is read-only archive after Phase 6 cutover.

  Not started under the supervision tree.
  """

  @doc """
  Returns true when R2 archive reads are explicitly allowed by operator flag.
  """
  @spec allowed?() :: boolean()
  def allowed? do
    Application.get_env(:unfinal, :allow_r2_archive_read?, false) or
      System.get_env("UNFINAL_ALLOW_R2_ARCHIVE_READ") == "true"
  end

  @doc """
  Read an object (index, etc.) from R2 archive. Returns
  `{:error, :r2_archive_read_disabled}` when `allowed?/0` is false.
  """
  @spec get_object(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_object(key) when is_binary(key) do
    if allowed?() do
      adapter().get_object(key)
    else
      {:error, :r2_archive_read_disabled}
    end
  end

  defp adapter, do: Application.get_env(:unfinal, :object_store_adapter, Unfinal.S3ObjectStore)
end
