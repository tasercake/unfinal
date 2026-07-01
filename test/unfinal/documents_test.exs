defmodule Unfinal.DocumentsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Unfinal.ContentStore
  alias Unfinal.Documents

  setup do
    Application.put_env(:unfinal, :storage_mode, :r2)
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    Documents.clear()

    # Clean SQLite tables before each test
    Unfinal.Repo.query("DELETE FROM documents", [])
    Unfinal.Repo.query("DELETE FROM namespace_claims", [])

    on_exit(fn ->
      Application.delete_env(:unfinal, :storage_mode)
      Documents.clear()
    end)
  end

  test "get returns latest queued content before durable flush" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.BlockingObjectStore)
    Unfinal.BlockingObjectStore.ensure_started()
    Unfinal.BlockingObjectStore.set_parent(self())
    Documents.clear()
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/slow"))

    assert :ok = Documents.queue_put("/slow", "draft")
    assert Documents.get("/slow").content == "draft"
    assert_receive :slow_put_started, 300
    assert Unfinal.FakeObjectStore.get("/slow") == {:ok, ContentStore.missing("/slow")}

    Unfinal.BlockingObjectStore.release_slow_put()
    assert_receive {:content_updated, "/slow", %{content: "draft"}}, 300
  end

  test "queue_put returns quickly and does not wait for slow persistence flush" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.BlockingObjectStore)
    Unfinal.BlockingObjectStore.ensure_started()
    Unfinal.BlockingObjectStore.set_parent(self())
    Documents.clear()
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/slow"))

    assert :ok = Documents.queue_put("/slow", "first")
    assert_receive :slow_put_started, 300

    {micros, result} = :timer.tc(fn -> Documents.queue_put("/slow", "second") end)
    assert result == :ok
    assert micros < 50_000
    assert Documents.get("/slow").content == "second"

    Unfinal.BlockingObjectStore.release_slow_put()
    assert_receive {:content_updated, "/slow", %{content: "second"}}, 500
    assert Documents.get("/slow").content == "second"
  end

  test "one document never runs parallel flush writes and coalesces latest content" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.BlockingObjectStore)
    Unfinal.BlockingObjectStore.ensure_started()
    Unfinal.BlockingObjectStore.set_parent(self())
    Documents.clear()
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/slow"))

    assert :ok = Documents.queue_put("/slow", "one")
    assert_receive :slow_put_started, 300
    assert :ok = Documents.queue_put("/slow", "two")
    refute_receive :slow_put_started, 50

    Unfinal.BlockingObjectStore.release_slow_put()
    assert_receive :slow_put_started, 300
    Unfinal.BlockingObjectStore.release_slow_put()

    assert_receive {:content_updated, "/slow", %{content: "two"}}, 500

    assert_eventually(fn ->
      {:ok, persisted} = Unfinal.FakeObjectStore.get("/slow")
      persisted.content == "two"
    end)
  end

  test "flush success persists and broadcasts latest content with metadata" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/queued"))

    assert :ok = Documents.queue_put("/queued", "two")

    assert_receive {:content_updated, "/queued", %{content: "two", revision: 1, etag: etag}}, 300
    assert is_binary(etag)
    assert Documents.get("/queued").content == "two"
  end

  test "queue_put persists empty and whitespace content instead of deleting" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/blank"))

    assert :ok = Documents.queue_put("/blank", "existing")
    assert_receive {:content_updated, "/blank", %{content: "existing", revision: 1}}, 300

    assert :ok = Documents.queue_put("/blank", "   \n\t")
    assert_receive {:content_updated, "/blank", %{content: "   \n\t", revision: 2}}, 300

    assert {:ok, %ContentStore.Document{content: "   \n\t", revision: 2, etag: etag}} =
             Unfinal.FakeObjectStore.get("/blank")

    assert is_binary(etag)

    assert :ok = Documents.queue_put("/blank", "")
    assert_receive {:content_updated, "/blank", %{content: "", revision: 3}}, 300

    assert {:ok, %ContentStore.Document{content: "", revision: 3, etag: etag}} =
             Unfinal.FakeObjectStore.get("/blank")

    assert is_binary(etag)
  end

  test "persistence failure keeps dirty content and retries latest content" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FlakyObjectStore)
    Unfinal.FlakyObjectStore.clear()
    Unfinal.FlakyObjectStore.fail_next_put()
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/flaky"))

    log =
      capture_log(fn ->
        assert :ok = Documents.queue_put("/flaky", "eventual")
        assert Documents.get("/flaky").content == "eventual"

        assert_receive {:content_updated, "/flaky", %{content: "eventual"}}, 500
      end)

    assert log =~ "content flush failed for /flaky: :temporary"
    assert Documents.get("/flaky").content == "eventual"
  end

  test "crashed flush task keeps dirty content and retries latest content" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.CrashingOnceObjectStore)
    Unfinal.CrashingOnceObjectStore.clear()
    Unfinal.CrashingOnceObjectStore.crash_next_put()
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/crashy"))

    log =
      capture_log(fn ->
        assert :ok = Documents.queue_put("/crashy", "survives crash")
        assert Documents.get("/crashy").content == "survives crash"

        assert_receive {:content_updated, "/crashy", %{content: "survives crash"}}, 500
      end)

    assert log =~ "content flush task crashed for /crashy"
    assert Documents.get("/crashy").content == "survives crash"
  end

  test "stale write result updates durable base and retries pending content" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.StaleOnceObjectStore)
    Unfinal.StaleOnceObjectStore.clear()
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/stale"))

    assert :ok = Documents.queue_put("/stale", "pending")

    assert_receive {:content_updated, "/stale", %{content: "pending", revision: 2}}, 500
    assert Documents.get("/stale").content == "pending"
  end

  test "successful R2 flush persists content to object store" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/alpha/notes"))

    assert :ok = Documents.queue_put("/alpha/notes", "persisted")

    assert_receive {:content_updated, "/alpha/notes", %{content: "persisted", revision: 1}}, 500

    # R2 FakeObjectStore has the persisted content
    assert_eventually(fn ->
      {:ok, doc} = Unfinal.FakeObjectStore.get("/alpha/notes")
      doc.content == "persisted"
    end)
  end

  test "R2 flush does not write to SQLite in R2 mode" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/alpha/r2only"))

    assert :ok = Documents.queue_put("/alpha/r2only", "r2 content")

    assert_receive {:content_updated, "/alpha/r2only", %{content: "r2 content"}}, 500

    # R2 FakeObjectStore has the persisted content
    assert_eventually(fn ->
      {:ok, doc} = Unfinal.FakeObjectStore.get("/alpha/r2only")
      doc.content == "r2 content"
    end)

    # SQLite documents table was NOT written to in R2 mode
    {:ok, %{rows: rows}} =
      Unfinal.Repo.query(
        "SELECT path FROM documents WHERE path = ?1",
        ["/alpha/r2only"]
      )

    assert rows == []
  end

  # ── SQLite-only mode tests ───────────────────────────────────────────────────

  test "sqlite-only: queue_put persists to SQLite and broadcasts" do
    Application.put_env(:unfinal, :storage_mode, :sqlite)
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/testns/saved"))

    assert :ok = Documents.queue_put("/testns/saved", "sqlite content")

    assert_receive {:content_updated, "/testns/saved", %{content: "sqlite content", revision: 1}},
                   500

    # Verify persisted in SQLite
    {:ok, %{rows: rows}} =
      Unfinal.Repo.query(
        "SELECT content, revision FROM documents WHERE path = ?1",
        ["/testns/saved"]
      )

    assert [["sqlite content", 1]] = rows
  after
    Application.delete_env(:unfinal, :storage_mode)
  end

  test "sqlite-only: get reads from SQLite" do
    Application.put_env(:unfinal, :storage_mode, :sqlite)

    assert :ok = Documents.queue_put("/testns/readme", "read this")
    assert Documents.get("/testns/readme").content == "read this"
  after
    Application.delete_env(:unfinal, :storage_mode)
  end

  test "sqlite-only: no R2 writes or reads during document save" do
    Application.put_env(:unfinal, :storage_mode, :sqlite)
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.R2WriteSpy)

    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/testns/spy"))

    assert :ok = Documents.queue_put("/testns/spy", "no r2")

    assert_receive {:content_updated, "/testns/spy", %{content: "no r2"}}, 500

    refute_received {:unexpected_r2_write, _, _}
    refute_received {:unexpected_r2_read, _, _}

    # Verify SQLite has the data
    assert Documents.get("/testns/spy").content == "no r2"
  after
    Application.delete_env(:unfinal, :storage_mode)
    Application.delete_env(:unfinal, :object_store_adapter)
  end

  test "sqlite-only: SQLite miss returns empty document without R2 fallback" do
    Application.put_env(:unfinal, :storage_mode, :sqlite)
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.R2WriteSpy)

    doc = Documents.get("/nonexistent/path")
    assert doc.content == ""
    assert doc.etag == nil
    assert doc.revision == 0

    refute_received {:unexpected_r2_read, _, _}
  after
    Application.delete_env(:unfinal, :storage_mode)
    Application.delete_env(:unfinal, :object_store_adapter)
  end

  test "sqlite-only: revision increments on successive writes" do
    Application.put_env(:unfinal, :storage_mode, :sqlite)
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/testns/versioned"))

    assert :ok = Documents.queue_put("/testns/versioned", "v1")
    assert_receive {:content_updated, "/testns/versioned", %{revision: 1}}, 500

    assert :ok = Documents.queue_put("/testns/versioned", "v2")
    assert_receive {:content_updated, "/testns/versioned", %{revision: 2}}, 500

    doc = Documents.get("/testns/versioned")
    assert doc.content == "v2"
    assert doc.revision == 2
    assert is_binary(doc.etag)
  after
    Application.delete_env(:unfinal, :storage_mode)
  end

  test "sqlite-only: empty content is persisted as-is" do
    Application.put_env(:unfinal, :storage_mode, :sqlite)
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/testns/empty"))

    assert :ok = Documents.queue_put("/testns/empty", "existing")
    assert_receive {:content_updated, "/testns/empty", %{content: "existing"}}, 500

    assert :ok = Documents.queue_put("/testns/empty", "")
    assert_receive {:content_updated, "/testns/empty", %{content: "", revision: 2}}, 500

    doc = Documents.get("/testns/empty")
    assert doc.content == ""
    assert doc.revision == 2
  after
    Application.delete_env(:unfinal, :storage_mode)
  end

  defp assert_eventually(fun, attempts \\ 30)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
