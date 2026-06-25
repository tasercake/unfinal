defmodule Unfinal.ContentStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.ContentStore

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    Unfinal.FakeObjectStore.clear()

    on_exit(fn -> Unfinal.FakeObjectStore.clear() end)
  end

  test "missing helper returns empty document with nil etag and revision zero" do
    assert %ContentStore.Document{content: "", etag: nil, revision: 0} = ContentStore.missing("/")
  end

  test "adapter creates and updates documents with conditional revisions" do
    assert {:ok, %{etag: nil, revision: 0}} = Unfinal.FakeObjectStore.get("/notes")

    assert {:ok, created} = Unfinal.FakeObjectStore.put("/notes", "hello", nil, 0)
    assert %ContentStore.Document{content: "hello", etag: etag1, revision: 1} = created
    assert is_binary(etag1)

    assert {:ok, updated} =
             Unfinal.FakeObjectStore.put("/notes", "world", created.etag, created.revision)

    assert %ContentStore.Document{content: "world", revision: 2} = updated
    assert updated.etag != etag1
    assert Unfinal.FakeObjectStore.get("/notes") == {:ok, updated}
  end

  test "adapter deletes blank-equivalent existing documents when called by document server" do
    assert {:ok, created} = Unfinal.FakeObjectStore.put("/blank-existing", "saved", nil, 0)
    assert Unfinal.FakeObjectStore.stored?("/blank-existing")

    assert {:ok, %ContentStore.Document{content: "", etag: nil, revision: 0}} =
             Unfinal.FakeObjectStore.delete("/blank-existing", created.etag, created.revision)

    refute Unfinal.FakeObjectStore.stored?("/blank-existing")
  end

  test "stale adapter writes return latest document and do not clobber" do
    assert {:ok, first} = Unfinal.FakeObjectStore.put("/notes", "first", nil, 0)

    assert {:ok, second} =
             Unfinal.FakeObjectStore.put("/notes", "second", first.etag, first.revision)

    assert {:stale, latest} =
             Unfinal.FakeObjectStore.put("/notes", "stale body", first.etag, first.revision)

    assert latest == second
    assert {:ok, %{content: "second"}} = Unfinal.FakeObjectStore.get("/notes")
  end

  test "object keys use documents prefix and sha256 path" do
    hash = :crypto.hash(:sha256, "/notes") |> Base.encode16(case: :lower)
    assert ContentStore.object_key("/notes") == "documents/#{hash}.txt"
  end

  test "content store does not start document servers" do
    assert Registry.lookup(Unfinal.DocumentRegistry, "/notes") == []
    assert {:ok, _doc} = Unfinal.FakeObjectStore.get("/notes")
    assert Registry.lookup(Unfinal.DocumentRegistry, "/notes") == []
  end
end
