defmodule Unfinal.DocumentsTest do
  use ExUnit.Case, async: false

  alias Unfinal.Documents

  setup do
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    Documents.clear()

    # Clean SQLite tables before each test
    Unfinal.Repo.query("DELETE FROM documents", [])
    Unfinal.Repo.query("DELETE FROM namespace_claims", [])

    on_exit(fn ->
      Documents.clear()
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

    assert :ok = Documents.queue_put("/blank", "")
    assert_receive {:content_updated, "/blank", %{content: "", revision: 3}}, 300
  end

  test "root content survives DocumentServer restart without clearing SQLite" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/"))

    assert :ok = Documents.queue_put("/", "root persists")
    assert_receive {:content_updated, "/", %{content: "root persists", revision: 1}}, 300

    assert_eventually(fn ->
      match?({:ok, %{content: "root persists", revision: 1}}, Unfinal.SqliteDocuments.fetch("/"))
    end)

    stop_document_server("/")
    wait_for_document_server_unregistered("/")

    assert Documents.get("/").content == "root persists"
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

  defp stop_document_server(path) do
    [{pid, _value}] = Registry.lookup(Unfinal.DocumentRegistry, path)
    monitor_ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(Unfinal.DocumentSupervisor, pid)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> flunk("DocumentServer did not stop")
    end
  end

  defp wait_for_document_server_unregistered(path, attempts \\ 50)

  defp wait_for_document_server_unregistered(_path, 0),
    do: flunk("DocumentServer stayed registered")

  defp wait_for_document_server_unregistered(path, attempts) do
    case Registry.lookup(Unfinal.DocumentRegistry, path) do
      [] ->
        :ok

      _registered ->
        Process.sleep(10)
        wait_for_document_server_unregistered(path, attempts - 1)
    end
  end
end
