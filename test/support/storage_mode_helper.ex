defmodule Unfinal.StorageModeHelper do
  @moduledoc "Helpers for testing different storage modes."

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
