defmodule Unfinal.ObjectIndex do
  @moduledoc "Small raw object helper for indexes."

  @type key :: String.t()

  @spec get(key()) :: {:ok, String.t()} | {:error, term()}
  def get(key) when is_binary(key) do
    adapter().get_object(key)
  end

  @spec put(key(), String.t()) :: {:error, :r2_archive_read_only}
  def put(_key, _content) do
    {:error, :r2_archive_read_only}
  end

  @spec adapter() :: module()
  defp adapter, do: Application.get_env(:unfinal, :object_store_adapter, Unfinal.S3ObjectStore)
end
