defmodule Unfinal.R2WriteSpy do
  @moduledoc """
  Test helper that fails the test on any R2 write or read attempt.

  Implements the ContentStore behaviour callbacks (`get/1`, `put/4`, `delete/4`,
  `clear/0`) plus `get_object/1` and `put_object/2` used by `ObjectIndex`.

  Every call sends `{:unexpected_r2_write, operation, args}` or
  `{:unexpected_r2_read, operation, args}` to the owner process (self())
  and returns an error or missing-document result.

  Use it only in tests that prove normal app flows do not touch R2.
  """

  @behaviour Unfinal.ContentStore

  alias Unfinal.ContentStore

  # ── ContentStore behaviour callbacks ──────────────────────────────────────────

  @impl true
  def get(path) do
    send(self(), {:unexpected_r2_read, :get, [path]})
    {:ok, ContentStore.missing(path)}
  end

  @impl true
  def put(path, content, base_etag, base_revision) do
    send(self(), {:unexpected_r2_write, :put, [path, content, base_etag, base_revision]})
    {:error, :unexpected_r2_write}
  end

  @impl true
  def delete(path, base_etag, base_revision) do
    send(self(), {:unexpected_r2_write, :delete, [path, base_etag, base_revision]})
    {:error, :unexpected_r2_write}
  end

  @impl true
  def clear, do: :ok

  # ── ObjectIndex helper callbacks ─────────────────────────────────────────────

  @spec get_object(String.t()) :: {:error, :unexpected_r2_read}
  def get_object(key) do
    send(self(), {:unexpected_r2_read, :get_object, [key]})
    {:error, :unexpected_r2_read}
  end

  @spec put_object(String.t(), String.t()) :: {:error, :unexpected_r2_write}
  def put_object(key, content) do
    send(self(), {:unexpected_r2_write, :put_object, [key, content]})
    {:error, :unexpected_r2_write}
  end
end
