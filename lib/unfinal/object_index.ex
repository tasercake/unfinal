defmodule Unfinal.ObjectIndex do
  @moduledoc "Small raw object helper for indexes."

  @type key :: String.t()

  @spec get(key()) :: {:ok, String.t()} | {:error, term()}
  def get(key) when is_binary(key) do
    adapter().get_object(key)
  end

  @spec put(key(), String.t()) :: :ok | {:error, term()}
  def put(key, content) when is_binary(key) and is_binary(content) do
    adapter().put_object(key, content)
  end

  @spec adapter() :: module()
  defp adapter, do: Application.get_env(:unfinal, :object_store_adapter, Unfinal.S3ObjectStore)
end
