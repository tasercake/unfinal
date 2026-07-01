defmodule Unfinal.StorageModeHelper do
  @moduledoc "Helpers for testing different storage modes."

  @doc """
  Set storage mode for the duration of a test via on_exit callback.
  """
  def set_storage_mode!(mode) do
    Application.put_env(:unfinal, :storage_mode, mode)
  end
end
