defmodule Unfinal.StorageModeHelper do
  @moduledoc "Helpers for testing different storage modes."

  @doc """
  Temporarily set the storage mode for a test.
  Restores the original mode on exit.

  Usage:
    import Unfinal.StorageModeHelper
    with_storage_mode(:sqlite_primary_r2_dual_write, fn -> ... end)
  """
  def with_storage_mode(mode, fun) do
    original = Application.get_env(:unfinal, :storage_mode)
    Application.put_env(:unfinal, :storage_mode, mode)

    try do
      fun.()
    after
      Application.put_env(:unfinal, :storage_mode, original)
    end
  end

  @doc """
  Set storage mode for the duration of a test via on_exit callback.
  """
  def set_storage_mode!(mode) do
    Application.put_env(:unfinal, :storage_mode, mode)
  end

  @doc """
  Set R2 read fallback for the duration of a test.
  """
  def set_r2_read_fallback!(enabled) do
    Application.put_env(:unfinal, :r2_read_fallback, enabled)
  end

  @doc """
  Set R2 dual-write for the duration of a test.
  """
  def set_r2_dual_write!(enabled) do
    Application.put_env(:unfinal, :r2_dual_write, enabled)
  end
end
