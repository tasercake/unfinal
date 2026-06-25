defmodule Unfinal.ContentStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.ContentStore

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    ContentStore.clear()

    on_exit(fn ->
      ContentStore.clear()
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

  test "blank new documents are not stored" do
    base = ContentStore.get("/blank-new")

    assert {:ok, %ContentStore.Document{content: "", etag: nil, revision: 0}} =
             ContentStore.put("/blank-new", "  \n\t  ", base.etag, base.revision)

    refute Unfinal.FakeObjectStore.stored?("/blank-new")

    assert %ContentStore.Document{content: "", etag: nil, revision: 0} =
             ContentStore.get("/blank-new")
  end

  test "blank existing documents are removed from storage" do
    base = ContentStore.get("/blank-existing")
    assert {:ok, created} = ContentStore.put("/blank-existing", "saved", base.etag, base.revision)
    assert Unfinal.FakeObjectStore.stored?("/blank-existing")

    assert {:ok, %ContentStore.Document{content: "", etag: nil, revision: 0}} =
             ContentStore.put("/blank-existing", "\n  ", created.etag, created.revision)

    refute Unfinal.FakeObjectStore.stored?("/blank-existing")

    assert %ContentStore.Document{content: "", etag: nil, revision: 0} =
             ContentStore.get("/blank-existing")
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

  test "get starts one document server for a path and reuses it" do
    assert Registry.lookup(Unfinal.DocumentRegistry, "/notes") == []

    assert %ContentStore.Document{} = ContentStore.get("/notes")
    assert [{pid, _value}] = Registry.lookup(Unfinal.DocumentRegistry, "/notes")

    assert %ContentStore.Document{} = ContentStore.get("/notes")
    assert Registry.lookup(Unfinal.DocumentRegistry, "/notes") == [{pid, nil}]
  end

  test "different paths use different document server pids" do
    ContentStore.get("/one")
    ContentStore.get("/two")

    assert [{one, _}] = Registry.lookup(Unfinal.DocumentRegistry, "/one")
    assert [{two, _}] = Registry.lookup(Unfinal.DocumentRegistry, "/two")
    assert one != two
  end

  test "clear stops document servers and clears adapter state" do
    base = ContentStore.get("/notes")
    assert {:ok, _doc} = ContentStore.put("/notes", "saved", base.etag, base.revision)
    assert [{pid, _}] = Registry.lookup(Unfinal.DocumentRegistry, "/notes")

    assert :ok = ContentStore.clear()
    refute Process.alive?(pid)
    assert Registry.lookup(Unfinal.DocumentRegistry, "/notes") == []
    assert ContentStore.get("/notes").content == ""
  end

  test "read failures return missing documents without stopping document server" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FailingObjectStore)

    assert %ContentStore.Document{path: "/outage", content: "", etag: nil, revision: 0} =
             ContentStore.get("/outage")

    assert [{pid, _}] = Registry.lookup(Unfinal.DocumentRegistry, "/outage")
    assert Process.alive?(pid)
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

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  test "slow flush for one document does not block a different document server" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.BlockingObjectStore)
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    Unfinal.BlockingObjectStore.ensure_started()
    Unfinal.BlockingObjectStore.set_parent(self())
    ContentStore.clear()

    assert :ok = ContentStore.queue_put("/slow", "slow")
    assert_receive :slow_put_started, 300
    assert [{slow_pid, _}] = Registry.lookup(Unfinal.DocumentRegistry, "/slow")

    assert %{etag: nil, revision: 0} = base = ContentStore.get("/fast")
    assert {:ok, fast} = ContentStore.put("/fast", "fast", base.etag, base.revision)
    assert fast.content == "fast"

    send(slow_pid, :release_slow_put)
    assert_eventually(fn -> ContentStore.get("/slow").content == "slow" end)
  end
end
