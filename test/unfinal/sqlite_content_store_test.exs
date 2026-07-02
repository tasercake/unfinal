defmodule Unfinal.SqliteContentStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.ContentStore.Document
  alias Unfinal.SqliteContentStore
  alias Unfinal.SQLiteCleanup

  setup do
    SQLiteCleanup.clear_all()
    on_exit(fn -> SQLiteCleanup.clear_all() end)
  end

  test "get returns content from SQLite" do
    SqliteContentStore.put("/test-doc", "hello", nil, 0)

    assert {:ok, %Document{content: "hello", revision: 1}} =
             SqliteContentStore.get("/test-doc")
  end

  test "get returns missing sentinel for absent document" do
    assert {:ok, %Document{content: "", etag: nil, revision: 0}} =
             SqliteContentStore.get("/nonexistent")
  end

  test "put with invalid base returns error" do
    result = SqliteContentStore.put("/test-doc", "content", "some-etag", 0)
    assert {:error, _} = result
  end

  test "revision increments on successive writes" do
    assert {:ok, %{revision: 1}} = SqliteContentStore.put("/versioned", "v1", nil, 0)
    assert {:ok, %{revision: 2}} = SqliteContentStore.put("/versioned", "v2", nil, 1)
  end

  test "delete removes document" do
    {:ok, %{etag: etag, revision: rev}} = SqliteContentStore.put("/deleteme", "bye", nil, 0)
    assert {:ok, %Document{content: ""}} = SqliteContentStore.delete("/deleteme", etag, rev)
    assert {:ok, %Document{content: "", revision: 0}} = SqliteContentStore.get("/deleteme")
  end
end
