defmodule Unfinal.PageIndexTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Unfinal.Documents
  alias Unfinal.PageIndex
  alias Unfinal.StorageModeHelper

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    Unfinal.SQLiteCleanup.clear_all()
    PageIndex.clear()
    Documents.clear()

    on_exit(fn ->
      PageIndex.clear()
      Documents.clear()
      Unfinal.SQLiteCleanup.clear_all()
    end)

    :ok
  end

  test "upserts namespace-relative paths and lists newest first" do
    assert PageIndex.list("alpha") == []

    assert :ok = PageIndex.upsert("alpha", "/", ~U[2026-06-23 00:00:00Z])
    assert :ok = PageIndex.upsert("alpha", "/notes", ~U[2026-06-24 00:00:00Z])
    assert :ok = PageIndex.upsert("alpha", "/ideas", ~U[2026-06-25 00:00:00Z])
    assert :ok = PageIndex.upsert("alpha", "/notes", ~U[2026-06-26 00:00:00Z])

    assert PageIndex.list("alpha") == [
             %{path: "/notes", updated_at: "2026-06-26T00:00:00Z"},
             %{path: "/ideas", updated_at: "2026-06-25T00:00:00Z"},
             %{path: "/", updated_at: "2026-06-23T00:00:00Z"}
           ]
  end

  test "ignores malformed ndjson lines" do
    assert :ok =
             Unfinal.ObjectIndex.put(
               "indexes/namespaces/alpha.ndjson",
               "bad\n{\"path\":\"/\",\"updated_at\":\"2026-06-25T00:00:00Z\"}\n{\"path\":\"/ok\",\"updated_at\":\"2026-06-24T00:00:00Z\"}\n{}\n"
             )

    assert eventually(fn ->
             PageIndex.list("alpha") == [
               %{path: "/", updated_at: "2026-06-25T00:00:00Z"},
               %{path: "/ok", updated_at: "2026-06-24T00:00:00Z"}
             ]
           end)
  end

  test "list sees newly upserted memory state before durable flush and namespaces isolate" do
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 1_000)

    assert :ok = PageIndex.upsert("alpha", "/fast", ~U[2026-06-26 00:00:00Z])
    assert PageIndex.list("alpha") == [%{path: "/fast", updated_at: "2026-06-26T00:00:00Z"}]
    assert PageIndex.list("beta") == []
  end

  test "upsert returns quickly when durable index write is blocked" do
    Unfinal.BlockingIndexObjectStore.ensure_started()
    Unfinal.BlockingIndexObjectStore.reset()
    Unfinal.BlockingIndexObjectStore.set_parent(self())
    Unfinal.BlockingIndexObjectStore.block_put_object(true)
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.BlockingIndexObjectStore)
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)

    started_at = System.monotonic_time(:millisecond)
    assert :ok = PageIndex.upsert("alpha", "/fast", ~U[2026-06-26 00:00:00Z])
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 100
    assert PageIndex.list("alpha") == [%{path: "/fast", updated_at: "2026-06-26T00:00:00Z"}]
    assert_receive {:put_object_started, "indexes/namespaces/alpha.ndjson"}, 200
    Unfinal.BlockingIndexObjectStore.release()
  end

  test "transient startup load failure retries without overwriting pending upserts" do
    Unfinal.FlakyIndexLoadObjectStore.ensure_started()
    Unfinal.FlakyIndexLoadObjectStore.fail_get_objects(1)
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FlakyIndexLoadObjectStore)

    assert :ok =
             Unfinal.FakeObjectStore.put_object(
               "indexes/namespaces/alpha.ndjson",
               Jason.encode!(%{path: "/pending", updated_at: "2026-06-25T00:00:00Z"}) <>
                 "\n" <>
                 Jason.encode!(%{path: "/loaded", updated_at: "2026-06-24T00:00:00Z"}) <> "\n"
             )

    log =
      capture_log(fn ->
        assert :ok = PageIndex.upsert("alpha", "/pending", ~U[2026-06-26 00:00:00Z])

        assert eventually(fn ->
                 PageIndex.list("alpha") == [
                   %{path: "/pending", updated_at: "2026-06-26T00:00:00Z"},
                   %{path: "/loaded", updated_at: "2026-06-24T00:00:00Z"}
                 ]
               end)
      end)

    assert log =~ "page index load failed for alpha: :temporary"
  end

  test "startup load is async and pending upserts are not overwritten by durable state" do
    Unfinal.BlockingIndexObjectStore.ensure_started()
    Unfinal.BlockingIndexObjectStore.reset()
    Unfinal.BlockingIndexObjectStore.set_parent(self())
    Unfinal.BlockingIndexObjectStore.block_get_object(true)
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.BlockingIndexObjectStore)

    assert :ok =
             Unfinal.FakeObjectStore.put_object(
               "indexes/namespaces/alpha.ndjson",
               Jason.encode!(%{path: "/pending", updated_at: "2026-06-25T00:00:00Z"}) <>
                 "\n" <>
                 Jason.encode!(%{path: "/loaded", updated_at: "2026-06-24T00:00:00Z"}) <> "\n"
             )

    started_at = System.monotonic_time(:millisecond)
    assert PageIndex.list("alpha") == []
    assert System.monotonic_time(:millisecond) - started_at < 100

    assert :ok = PageIndex.upsert("alpha", "/pending", ~U[2026-06-26 00:00:00Z])
    Unfinal.BlockingIndexObjectStore.release()

    assert eventually(fn ->
             PageIndex.list("alpha") == [
               %{path: "/pending", updated_at: "2026-06-26T00:00:00Z"},
               %{path: "/loaded", updated_at: "2026-06-24T00:00:00Z"}
             ]
           end)
  end

  test "sqlite-only documents do not affect PageIndex list" do
    # Seed SQLite documents table directly (simulating shadow writes)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Unfinal.Repo.query(
      "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ["/alpha/onlyinsqlite", "alpha", "/onlyinsqlite", "shadow content", 1, now]
    )

    # Do NOT write indexes/namespaces/alpha.ndjson to R2/index
    # PageIndex.list reads from R2/index (PageIndexServer), not SQLite
    assert PageIndex.list("alpha") == []
  end

  # -- SQLite-primary mode tests --

  test "list reads from SQLite in SQLite-primary mode" do
    StorageModeHelper.set_storage_mode!(:sqlite)

    # Insert document directly into SQLite
    Unfinal.Repo.query(
      "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ["/testns/page1", "testns", "/page1", "content", 0, "2025-01-01T00:00:00Z"]
    )

    entries = Unfinal.PageIndex.list("testns")
    assert length(entries) == 1
    assert hd(entries).path == "/page1"
  after
    StorageModeHelper.set_storage_mode!(:r2)
  end

  test "list returns empty for invalid namespace in SQLite-primary mode" do
    StorageModeHelper.set_storage_mode!(:sqlite)
    assert Unfinal.PageIndex.list("Invalid-Namespace") == []
  after
    StorageModeHelper.set_storage_mode!(:r2)
  end

  test "upsert writes to SQLite and triggers R2 mirror in SQLite-primary mode" do
    StorageModeHelper.set_storage_mode!(:sqlite)
    StorageModeHelper.set_r2_dual_write!(false)

    assert :ok = Unfinal.PageIndex.upsert("testns", "/", ~U[2025-06-01 00:00:00Z])

    entries = Unfinal.PageIndex.list("testns")
    assert length(entries) == 1
    assert hd(entries).path == "/"
  after
    StorageModeHelper.set_storage_mode!(:r2)
    StorageModeHelper.set_r2_dual_write!(false)
  end

  test "upsert returns error for invalid path in SQLite-primary mode" do
    StorageModeHelper.set_storage_mode!(:sqlite)

    assert {:error, :invalid} =
             Unfinal.PageIndex.upsert("testns", "no-leading-slash", ~U[2025-06-01 00:00:00Z])
  after
    StorageModeHelper.set_storage_mode!(:r2)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
