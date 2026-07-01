defmodule Unfinal.S3ObjectStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.S3ObjectStore

  setup do
    previous_config = Application.get_env(:unfinal, :s3)

    on_exit(fn ->
      if previous_config do
        Application.put_env(:unfinal, :s3, previous_config)
      else
        Application.delete_env(:unfinal, :s3)
      end
    end)

    :ok
  end

  test "put returns {:error, :r2_archive_read_only}" do
    assert {:error, :r2_archive_read_only} = S3ObjectStore.put("/notes", "hello", nil, 0)
  end

  test "put with existing etag returns {:error, :r2_archive_read_only}" do
    assert {:error, :r2_archive_read_only} =
             S3ObjectStore.put("/notes", "hello", "etag-1", 1)
  end

  test "put with nil etag and non-zero revision returns {:error, :r2_archive_read_only}" do
    assert {:error, :r2_archive_read_only} =
             S3ObjectStore.put("/notes", "hello", nil, 5)
  end

  test "delete returns {:error, :r2_archive_read_only}" do
    assert {:error, :r2_archive_read_only} =
             S3ObjectStore.delete("/notes", "etag-1", 1)
  end

  test "delete with nil etag returns {:error, :r2_archive_read_only}" do
    assert {:error, :r2_archive_read_only} =
             S3ObjectStore.delete("/notes", nil, 0)
  end
end
