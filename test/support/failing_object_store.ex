defmodule Unfinal.FailingObjectStore do
  @behaviour Unfinal.ContentStore

  @impl true
  def get(_path), do: {:error, :read_failed}

  @impl true
  def put(_path, _content, _base_etag, _base_revision), do: {:error, :write_not_supported}

  @impl true
  def clear, do: :ok
end
