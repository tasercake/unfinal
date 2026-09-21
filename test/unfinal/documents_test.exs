defmodule Unfinal.DocumentsTest do
  use ExUnit.Case, async: false

  alias Unfinal.Documents
  alias Unfinal.SQLiteFixtures

  setup do
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    Documents.clear()

    # Clean SQLite tables before each test
    Unfinal.Repo.query("DELETE FROM documents", [])
    Unfinal.Repo.query("DELETE FROM namespace_claims", [])
    SQLiteFixtures.claim_namespace("queued")
    SQLiteFixtures.claim_namespace("blank")

    on_exit(fn ->
      Documents.clear()
    end)
  end

  test "flush success persists and broadcasts latest content with metadata" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/queued"))

    assert :ok = Documents.queue_put("/queued", "Queued title", "two")

    assert_receive {:content_updated, "/queued",
                    %{title: "Queued title", content: "two", revision: 1, etag: etag}},
                   300

    assert is_binary(etag)
    assert Documents.get("/queued").content == "two"
  end

  test "queue_put persists empty and whitespace content instead of deleting" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/blank"))

    assert :ok = Documents.queue_put("/blank", "Blank", "existing")
    assert_receive {:content_updated, "/blank", %{content: "existing", revision: 1}}, 300

    assert :ok = Documents.queue_put("/blank", "Blank", "   \n\t")
    assert_receive {:content_updated, "/blank", %{content: "   \n\t", revision: 2}}, 300

    assert :ok = Documents.queue_put("/blank", "Blank", "")
    assert_receive {:content_updated, "/blank", %{content: "", revision: 3}}, 300
  end

  test "root content survives DocumentServer restart without clearing SQLite" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/"))

    assert :ok = Documents.queue_put("/", "Root", "root persists")
    assert_receive {:content_updated, "/", %{content: "root persists", revision: 1}}, 300

    assert_eventually(fn ->
      match?({:ok, %{content: "root persists", revision: 1}}, Unfinal.SqliteDocuments.fetch("/"))
    end)

    stop_document_server("/")
    wait_for_document_server_unregistered("/")

    assert Documents.get("/").content == "root persists"
  end

  test "namespace owner moves a document and keeps the old path as a redirect" do
    :ok =
      Unfinal.NamespaceStore.claim("alpha", %{
        "id" => "owner",
        "email" => "owner@example.com"
      })

    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/alpha/notes"))
    assert :ok = Documents.queue_put("/alpha/notes", "", "rough notes")
    assert_receive {:content_updated, "/alpha/notes", %{content: "rough notes"}}, 300

    assert :ok = Documents.move("/alpha/notes", "/alpha/ideas/notes", "owner")

    assert Documents.get("/alpha/notes").content == ""
    assert Documents.get("/alpha/ideas/notes").content == "rough notes"
    assert Documents.resolve_path("/alpha/notes") == {:redirect, "/alpha/ideas/notes"}
    assert Documents.resolve_path("/alpha/ideas/notes") == :document
  end

  test "move flushes the latest queued edit before changing the path" do
    :ok =
      Unfinal.NamespaceStore.claim("alpha", %{
        "id" => "owner",
        "email" => "owner@example.com"
      })

    assert :ok = Documents.queue_put("/alpha/notes", "", "typed just before move")
    assert :ok = Documents.move("/alpha/notes", "/alpha/moved", "owner")

    assert Documents.get("/alpha/moved").content == "typed just before move"
  end

  test "move rejects occupied and permanently reserved destinations" do
    :ok =
      Unfinal.NamespaceStore.claim("alpha", %{
        "id" => "owner",
        "email" => "owner@example.com"
      })

    persist_document("/alpha/one", "one")
    persist_document("/alpha/two", "two")

    assert {:error, :destination_taken} =
             Documents.move("/alpha/one", "/alpha/two", "owner")

    assert :ok = Documents.move("/alpha/one", "/alpha/three", "owner")

    assert {:error, :destination_taken} =
             Documents.move("/alpha/two", "/alpha/one", "owner")
  end

  test "move stays inside the owned namespace and excludes its root" do
    :ok =
      Unfinal.NamespaceStore.claim("alpha", %{
        "id" => "owner",
        "email" => "owner@example.com"
      })

    persist_document("/alpha", "home")
    persist_document("/alpha/notes", "notes")

    assert {:error, :cannot_move_root} = Documents.move("/alpha", "/alpha/home", "owner")

    assert {:error, :cannot_replace_root} =
             Documents.move("/alpha/notes", "/alpha", "owner")

    assert {:error, :cross_namespace} =
             Documents.move("/alpha/notes", "/beta/notes", "owner")

    assert {:error, :not_authorized} =
             Documents.move("/alpha/notes", "/alpha/moved", "other")
  end

  test "later moves collapse every old address to the latest path" do
    :ok =
      Unfinal.NamespaceStore.claim("alpha", %{
        "id" => "owner",
        "email" => "owner@example.com"
      })

    persist_document("/alpha/one", "one")

    assert :ok = Documents.move("/alpha/one", "/alpha/two", "owner")
    assert :ok = Documents.move("/alpha/two", "/alpha/three", "owner")

    assert Documents.resolve_path("/alpha/one") == {:redirect, "/alpha/three"}
    assert Documents.resolve_path("/alpha/two") == {:redirect, "/alpha/three"}
  end

  test "late edit on a moved path repeats the move notification without recreating it" do
    :ok =
      Unfinal.NamespaceStore.claim("alpha", %{
        "id" => "owner",
        "email" => "owner@example.com"
      })

    persist_document("/alpha/notes", "notes")
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.move_topic("/alpha/notes"))

    assert :ok = Documents.move("/alpha/notes", "/alpha/moved", "owner")
    assert_receive {:document_moved, "/alpha/notes", "/alpha/moved"}, 300

    assert :ok = Documents.queue_put("/alpha/notes", "", "late stale edit")
    assert_receive {:document_moved, "/alpha/notes", "/alpha/moved"}, 300

    assert Documents.resolve_path("/alpha/notes") == {:redirect, "/alpha/moved"}
    assert Documents.get("/alpha/moved").content == "notes"
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

  defp persist_document(path, content) do
    assert {:ok, _document} = Unfinal.SqliteDocuments.put(path, "", content, nil, 0)
  end

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
