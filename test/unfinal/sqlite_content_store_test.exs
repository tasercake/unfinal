defmodule Unfinal.SqliteContentStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.ContentStore
  alias Unfinal.ContentStore.Document
  alias Unfinal.SqliteContentStore
  alias Unfinal.SQLiteCleanup

  setup do
    # Set SQLite-primary mode for these tests
    Application.put_env(:unfinal, :storage_mode, :sqlite)

    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    Unfinal.FakeObjectStore.ensure_started()

    SQLiteCleanup.clear_all()
    Unfinal.FakeObjectStore.clear()

    # Bridge S3ObjectStore → FakeObjectStore for R2 fallback tests
    original_s3 = Application.get_env(:unfinal, :s3, [])

    Application.put_env(:unfinal, :s3,
      request_fun: fn
        :get, key, _headers, _body ->
          case Unfinal.FakeObjectStore.get_object(key) do
            {:ok, content} ->
              {:ok, 200,
               %{
                 "etag" => "test-etag",
                 "x-amz-meta-unfinal-revision" => "1",
                 "x-amz-meta-unfinal-write-id" => "test-write"
               }, content}

            {:error, _} ->
              {:ok, 404, %{}, ""}
          end

        :put, key, _headers, body ->
          Unfinal.FakeObjectStore.put_object(key, body)
          {:ok, 201, %{"etag" => "test-etag"}, ""}
      end
    )

    on_exit(fn ->
      SQLiteCleanup.clear_all()
      Unfinal.FakeObjectStore.clear()
      Application.put_env(:unfinal, :storage_mode, :r2)

      Application.put_env(:unfinal, :s3, original_s3)
    end)
  end

  test "SQLite hit returns content and does not read R2" do
    # Write directly to SQLite
    SqliteContentStore.put("/test-doc", "sqlite content", nil, 0)

    # Read — should come from SQLite, not R2
    assert {:ok, %Document{content: "sqlite content", revision: 1}} =
             SqliteContentStore.get("/test-doc")

    # R2 should not have this document
    refute Unfinal.FakeObjectStore.stored?("/test-doc")
  end

  test "SQLite miss + R2 missing returns missing sentinel" do
    assert {:ok, %Document{content: "", etag: nil, revision: 0}} =
             SqliteContentStore.get("/nonexistent")
  end

  test "SQLite miss returns missing without R2 fallback" do
    # Write to R2 only (simulating pre-migration data)
    key = ContentStore.object_key("/r2-doc")
    Unfinal.FakeObjectStore.put_object(key, "r2 content")

    # Read via SqliteContentStore — no R2 fallback, returns missing
    assert {:ok, %Document{content: "", etag: nil, revision: 0}} =
             SqliteContentStore.get("/r2-doc")

    # SQLite still has no document
    assert {:error, :not_found} = Unfinal.SqliteDocuments.fetch("/r2-doc")
  end

  test "SQLite write with invalid base returns error" do
    # Passing base_etag with 0 revision should return error
    result = SqliteContentStore.put("/test-doc", "content", "some-etag", 0)
    assert {:error, _} = result
  end

  test "SQLite miss returns missing even when R2 has data" do
    # R2 has data, but SQLite is source of truth
    key = ContentStore.object_key("/r2-only")
    Unfinal.FakeObjectStore.put_object(key, "r2 content")

    # No fallback — SQLite miss returns missing
    assert {:ok, %Document{content: "", etag: nil, revision: 0}} =
             SqliteContentStore.get("/r2-only")
  end
end
