defmodule Unfinal.R2MirrorFailureObjectStore do
  @moduledoc """
  Wraps FakeObjectStore but fails all put_object/2 calls (simulating R2 outage).
  Used to verify that SQLite primary writes succeed even when R2 mirror fails.
  """

  @doc "Simulate R2 outage for put_object calls (mirrors)."
  def put_object(_key, _content) do
    {:error, :r2_unavailable}
  end

  @doc "Delegate get_object to FakeObjectStore."
  defdelegate get_object(key), to: Unfinal.FakeObjectStore

  @doc "Delegate get to FakeObjectStore."
  defdelegate get(path), to: Unfinal.FakeObjectStore

  @doc "Delegate put to FakeObjectStore."
  defdelegate put(path, content, base_etag, base_revision), to: Unfinal.FakeObjectStore

  @doc "Delegate delete to FakeObjectStore."
  defdelegate delete(path, base_etag, base_revision), to: Unfinal.FakeObjectStore

  @doc "Delegate clear to FakeObjectStore."
  defdelegate clear(), to: Unfinal.FakeObjectStore
end
