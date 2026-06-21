defmodule Unfinal.FilesystemObjectStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.ContentStore
  alias Unfinal.FilesystemObjectStore

  setup do
    previous_data_dir = System.get_env("UNFINAL_DATA_DIR")
    previous_config = Application.get_env(:unfinal, :filesystem_object_store)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "unfinal-filesystem-object-store-#{System.unique_integer([:positive])}"
      )

    System.put_env("UNFINAL_DATA_DIR", data_dir)
    Application.put_env(:unfinal, :filesystem_object_store, write_delay_ms: 0)
    File.rm_rf!(data_dir)

    on_exit(fn ->
      File.rm_rf!(data_dir)

      if previous_data_dir do
        System.put_env("UNFINAL_DATA_DIR", previous_data_dir)
      else
        System.delete_env("UNFINAL_DATA_DIR")
      end

      if previous_config do
        Application.put_env(:unfinal, :filesystem_object_store, previous_config)
      else
        Application.delete_env(:unfinal, :filesystem_object_store)
      end
    end)

    %{data_dir: data_dir}
  end

  test "missing get returns empty document" do
    assert {:ok, %ContentStore.Document{path: "/missing", content: "", etag: nil, revision: 0}} =
             FilesystemObjectStore.get("/missing")
  end

  test "creates and updates JSON envelope documents" do
    assert {:ok, created} = FilesystemObjectStore.put("/notes", "hello", nil, 0)

    assert %ContentStore.Document{path: "/notes", content: "hello", revision: 1, etag: etag1} =
             created

    assert is_binary(etag1)

    assert {:ok, fetched} = FilesystemObjectStore.get("/notes")
    assert fetched == created

    assert {:ok, updated} = FilesystemObjectStore.put("/notes", "world", etag1, 1)
    assert %ContentStore.Document{content: "world", revision: 2, etag: etag2} = updated
    assert etag2 != etag1
  end

  test "stale write returns current document and leaves file unchanged" do
    assert {:ok, first} = FilesystemObjectStore.put("/notes", "first", nil, 0)

    assert {:ok, second} =
             FilesystemObjectStore.put("/notes", "second", first.etag, first.revision)

    assert {:stale, ^second} =
             FilesystemObjectStore.put("/notes", "stale", first.etag, first.revision)

    assert {:ok, ^second} = FilesystemObjectStore.get("/notes")
  end

  test "clear deletes only managed document JSON files", %{data_dir: data_dir} do
    File.mkdir_p!(data_dir)
    File.write!(Path.join(data_dir, "namespaces.txt"), "alpha\tone@example.com\n")
    assert {:ok, _doc} = FilesystemObjectStore.put("/notes", "body", nil, 0)

    assert :ok = FilesystemObjectStore.clear()

    assert File.exists?(Path.join(data_dir, "namespaces.txt"))

    assert {:ok, %ContentStore.Document{content: "", revision: 0}} =
             FilesystemObjectStore.get("/notes")
  end

  test "honors zero write delay" do
    Application.put_env(:unfinal, :filesystem_object_store, write_delay_ms: 0)

    {microseconds, {:ok, _doc}} =
      :timer.tc(fn -> FilesystemObjectStore.put("/fast", "body", nil, 0) end)

    assert microseconds < 100_000
  end
end
