defmodule Unfinal.DocumentsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Unfinal.ContentStore
  alias Unfinal.Documents

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    Documents.clear()

    on_exit(fn ->
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

  test "persistence failure keeps dirty content and retries latest content" do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FlakyObjectStore)
    Unfinal.FlakyObjectStore.clear()
    Unfinal.FlakyObjectStore.fail_next_put()
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/flaky"))

    assert :ok = Documents.queue_put("/flaky", "eventual")
    assert Documents.get("/flaky").content == "eventual"

    assert_receive {:content_updated, "/flaky", %{content: "eventual"}}, 500
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
