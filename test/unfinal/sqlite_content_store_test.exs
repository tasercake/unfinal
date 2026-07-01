defmodule Unfinal.SqliteContentStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.ContentStore
  alias Unfinal.ContentStore.Document
  alias Unfinal.SqliteContentStore
  alias Unfinal.SQLiteCleanup
  alias Unfinal.StorageModeHelper

  setup do
    # Set Phase 5 mode for these tests
    StorageModeHelper.set_storage_mode!(:sqlite_primary_r2_dual_write)
    StorageModeHelper.set_r2_read_fallback!(true)
    StorageModeHelper.set_r2_dual_write!(false)
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
      StorageModeHelper.set_storage_mode!(:r2_primary_sqlite_shadow)
      StorageModeHelper.set_r2_read_fallback!(false)
      StorageModeHelper.set_r2_dual_write!(false)
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

  test "SQLite miss + R2 present repairs SQLite with insert-if-absent" do
    # Write to R2 only (simulating Phase 4 data)
    # Store the document content at the S3 object key for the request_fun bridge
    key = ContentStore.object_key("/r2-doc")
    Unfinal.FakeObjectStore.put_object(key, "r2 content")

    # Read via SqliteContentStore — should fallback to R2, repair SQLite
    assert {:ok, %Document{content: "r2 content"}} = SqliteContentStore.get("/r2-doc")

    # Verify SQLite now has the document
    assert {:ok, %{content: "r2 content"}} =
             Unfinal.SqliteDocuments.fetch("/r2-doc")

    # Subsequent reads come from SQLite, not R2 (clear R2 to prove it)
    Unfinal.FakeObjectStore.clear()
    assert {:ok, %Document{content: "r2 content"}} = SqliteContentStore.get("/r2-doc")
  end

  test "SQLite write with invalid base returns error" do
    # Passing base_etag with 0 revision should return error
    result = SqliteContentStore.put("/test-doc", "content", "some-etag", 0)
    assert {:error, _} = result
  end

  test "R2 fallback disabled returns missing on SQLite miss" do
    StorageModeHelper.set_r2_read_fallback!(false)

    # Write to R2 only via S3ObjectStore bridge
    key = ContentStore.object_key("/r2-only")
    Unfinal.FakeObjectStore.put_object(key, "r2 content")

    # Read with fallback disabled — should return missing
    assert {:ok, %Document{content: "", etag: nil, revision: 0}} =
             SqliteContentStore.get("/r2-only")
  end
end
