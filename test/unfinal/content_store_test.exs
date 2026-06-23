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

  test "broadcasts accepted changes with content, revision, and etag on path topic" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, ContentStore.topic("/notes"))

    base = ContentStore.get("/notes")
    assert {:ok, doc} = ContentStore.put("/notes", "live", base.etag, base.revision)

    assert_receive {:content_updated, "/notes", %{content: "live", revision: 1, etag: etag}}
    assert etag == doc.etag
    refute_receive {:content_updated, "/other", _}
  end

  test "object keys use documents prefix and sha256 path" do
    hash = :crypto.hash(:sha256, "/notes") |> Base.encode16(case: :lower)
    assert ContentStore.object_key("/notes") == "documents/#{hash}.txt"
  end

  test "read failures return missing documents without stopping ContentStore" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FailingObjectStore)

    assert %ContentStore.Document{path: "/outage", content: "", etag: nil, revision: 0} =
             ContentStore.get("/outage")

    assert Process.alive?(Process.whereis(ContentStore))
  end

  test "queued puts coalesce, persist latest content, and broadcast only after durable flush" do
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    Phoenix.PubSub.subscribe(Unfinal.PubSub, ContentStore.topic("/queued"))

    assert :ok = ContentStore.queue_put("/queued", "one")
    assert :ok = ContentStore.queue_put("/queued", "two")
    refute_receive {:content_updated, "/queued", _}, 5

    assert_receive {:content_updated, "/queued", %{content: "two", revision: 1, etag: etag}}, 200
    assert is_binary(etag)
    assert ContentStore.get("/queued").content == "two"
    refute_receive {:content_updated, "/queued", _}, 30
  end

  test "queued put flush retry keeps final pending content after durable write failure" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FlakyObjectStore)
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    Unfinal.FlakyObjectStore.clear()
    Unfinal.FlakyObjectStore.fail_next_put()
    Phoenix.PubSub.subscribe(Unfinal.PubSub, ContentStore.topic("/flaky"))

    assert :ok = ContentStore.queue_put("/flaky", "eventual")
    refute_receive {:content_updated, "/flaky", _}, 15

    assert_receive {:content_updated, "/flaky", %{content: "eventual"}}, 250
    assert ContentStore.get("/flaky").content == "eventual"
  end

  test "queued stale flush updates base and retries pending content" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.StaleOnceObjectStore)
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    Unfinal.StaleOnceObjectStore.clear()
    Phoenix.PubSub.subscribe(Unfinal.PubSub, ContentStore.topic("/stale"))

    assert :ok = ContentStore.queue_put("/stale", "pending")

    assert_receive {:content_updated, "/stale", %{content: "pending", revision: 2}}, 250
    assert ContentStore.get("/stale").content == "pending"
  end

  test "ContentStore keeps serving puts and gets after failed reads" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FailingObjectStore)
    assert %ContentStore.Document{} = ContentStore.get("/temporary-outage")

    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)

    assert %{etag: nil, revision: 0} = base = ContentStore.get("/after-outage")
    assert {:ok, doc} = ContentStore.put("/after-outage", "still alive", base.etag, base.revision)
    assert ContentStore.get("/after-outage") == doc
  end
end
