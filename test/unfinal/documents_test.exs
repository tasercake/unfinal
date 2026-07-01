defmodule Unfinal.DocumentsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Unfinal.ContentStore
  alias Unfinal.Documents

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    Documents.clear()

    # Clean SQLite tables before each test
    Unfinal.Repo.query("DELETE FROM documents", [])
    Unfinal.Repo.query("DELETE FROM namespace_claims", [])

    on_exit(fn ->
      Documents.clear()
      # Restore default repo in case test overrode it
      Application.put_env(:unfinal, :sqlite_shadow_repo, Unfinal.Repo)
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

  test "successful R2 flush shadow upserts SQLite document" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/alpha/notes"))

    assert :ok = Documents.queue_put("/alpha/notes", "shadowed")

    assert_receive {:content_updated, "/alpha/notes", %{content: "shadowed", revision: 1}}, 500

    # R2 FakeObjectStore has the persisted content
    assert_eventually(fn ->
      {:ok, doc} = Unfinal.FakeObjectStore.get("/alpha/notes")
      doc.content == "shadowed"
    end)

    # SQLite documents row was shadow-upserted
    {:ok, %{rows: rows}} =
      Unfinal.Repo.query(
        "SELECT path, namespace, relative_path, content, revision FROM documents WHERE path = ?1",
        ["/alpha/notes"]
      )

    assert [["/alpha/notes", "alpha", "/notes", "shadowed", 1]] = rows
  end

  test "sqlite shadow failure does not fail document save or R2 persistence" do
    Application.put_env(:unfinal, :sqlite_shadow_repo, Unfinal.FailingSQLiteShadowRepo)

    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/alpha/fail-shadow"))

    log =
      capture_log(fn ->
        assert :ok = Documents.queue_put("/alpha/fail-shadow", "r2 wins")

        assert_receive {:content_updated, "/alpha/fail-shadow", %{content: "r2 wins"}}, 500
      end)

    # R2 FakeObjectStore has the persisted content
    assert_eventually(fn ->
      {:ok, doc} = Unfinal.FakeObjectStore.get("/alpha/fail-shadow")
      doc.content == "r2 wins"
    end)

    assert log =~ "sqlite shadow document upsert failed for /alpha/fail-shadow"
  end

  test "document shadow upsert does not clobber newer SQLite row" do
    # Seed SQLite row with a much higher revision
    seed_sql = """
    INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    """

    Unfinal.Repo.query(seed_sql, [
      "/alpha/stale",
      "alpha",
      "/stale",
      "newer sqlite",
      99,
      DateTime.to_iso8601(~U[2025-01-01 00:00:00Z])
    ])

    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/alpha/stale"))

    assert :ok = Documents.queue_put("/alpha/stale", "older r2 revision")

    assert_receive {:content_updated, "/alpha/stale",
                    %{content: "older r2 revision", revision: 1}},
                   500

    # R2 FakeObjectStore has the new content at revision 1
    assert_eventually(fn ->
      {:ok, doc} = Unfinal.FakeObjectStore.get("/alpha/stale")
      doc.content == "older r2 revision" and doc.revision == 1
    end)

    # SQLite row remains unchanged at revision 99
    {:ok, %{rows: rows}} =
      Unfinal.Repo.query(
        "SELECT content, revision FROM documents WHERE path = ?1",
        ["/alpha/stale"]
      )

    assert [["newer sqlite", 99]] = rows
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
