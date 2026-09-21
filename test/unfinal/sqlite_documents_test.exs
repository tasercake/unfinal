defmodule Unfinal.SqliteDocumentsTest do
  use ExUnit.Case, async: false

  alias Unfinal.ContentStore.Document
  alias Unfinal.SQLiteCleanup
  alias Unfinal.SQLiteFixtures
  alias Unfinal.SqliteDocuments

  setup do
    SQLiteCleanup.clear_all()
    on_exit(fn -> SQLiteCleanup.clear_all() end)
  end

  test "put persists the global root document" do
    assert {:ok, %Document{path: "/", title: "Home", content: "root body", revision: 1}} =
             SqliteDocuments.put("/", "Home", "root body", nil, 0)

    assert {:ok, %Document{path: "/", title: "Home", content: "root body", revision: 1}} =
             SqliteDocuments.fetch("/")

    assert {:ok, %{rows: [[nil, "/"]]}} =
             Unfinal.Repo.query(
               "SELECT namespace, relative_path FROM documents WHERE path = ?1",
               ["/"],
               timeout: 5_000
             )
  end

  test "put rejects a document without a matching namespace claim" do
    assert {:error, reason} = SqliteDocuments.put("/unclaimed/page", "", "body", nil, 0)
    assert inspect(reason) =~ "FOREIGN KEY constraint failed"
    assert {:error, :not_found} = SqliteDocuments.fetch("/unclaimed/page")
  end

  test "database reserves a nil namespace for the global root document" do
    assert {:error, reason} =
             Unfinal.Repo.query(
               "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, NULL, ?2, '', 0, ?3)",
               ["/not-root", "/", "2026-09-21T00:00:00Z"],
               timeout: 5_000
             )

    assert inspect(reason) =~ "documents_root_namespace_check"
  end

  test "put cannot recreate a path reserved by a move redirect" do
    SQLiteFixtures.claim_namespace("alpha")

    assert {:ok, _document} = SqliteDocuments.put("/alpha/notes", "", "notes", nil, 0)
    assert :ok = SqliteDocuments.move("/alpha/notes", "/alpha/moved")

    assert {:error, :path_redirected} =
             SqliteDocuments.put("/alpha/notes", "", "stale edit", nil, 0)

    assert SqliteDocuments.resolve_path("/alpha/notes") == {:redirect, "/alpha/moved"}
  end
end
