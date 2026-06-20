defmodule Unfinal.ContentStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.ContentStore

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    ContentStore.clear()

    on_exit(fn ->
      ContentStore.clear()
      Application.delete_env(:unfinal, :object_store_adapter)
    end)
  end

  test "missing paths return empty document with nil etag and revision zero" do
    assert %ContentStore.Document{content: "", etag: nil, revision: 0} = ContentStore.get("/")
  end

  test "creates and updates documents with conditional revisions" do
    assert %{etag: nil, revision: 0} = base = ContentStore.get("/notes")

    assert {:ok, created} = ContentStore.put("/notes", "hello", base.etag, base.revision)
    assert %ContentStore.Document{content: "hello", etag: etag1, revision: 1} = created
    assert is_binary(etag1)

    assert {:ok, updated} = ContentStore.put("/notes", "world", created.etag, created.revision)
    assert %ContentStore.Document{content: "world", revision: 2} = updated
    assert updated.etag != etag1
    assert ContentStore.get("/notes") == updated
  end

  test "stale writes return latest document and do not clobber" do
    base = ContentStore.get("/notes")
    assert {:ok, first} = ContentStore.put("/notes", "first", base.etag, base.revision)
    assert {:ok, second} = ContentStore.put("/notes", "second", first.etag, first.revision)

    assert {:stale, latest} = ContentStore.put("/notes", "stale body", first.etag, first.revision)
    assert latest == second
    assert ContentStore.get("/notes").content == "second"
  end

  test "broadcasts accepted changes with revision and etag only on path topic" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, ContentStore.topic("/notes"))

    base = ContentStore.get("/notes")
    assert {:ok, doc} = ContentStore.put("/notes", "live", base.etag, base.revision)

    assert_receive {:content_updated, "/notes", %{revision: 1, etag: etag}}
    assert etag == doc.etag
    refute_receive {:content_updated, "/other", _}
  end

  test "object keys use documents prefix and sha256 path" do
    hash = :crypto.hash(:sha256, "/notes") |> Base.encode16(case: :lower)
    assert ContentStore.object_key("/notes") == "documents/#{hash}.txt"
  end
end
