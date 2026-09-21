defmodule Unfinal.SqliteDocumentsTest do
  use ExUnit.Case, async: false

  alias Unfinal.ContentStore.Document
  alias Unfinal.SQLiteCleanup
  alias Unfinal.SqliteDocuments

  setup do
    SQLiteCleanup.clear_all()
    on_exit(fn -> SQLiteCleanup.clear_all() end)
  end

  test "put persists the global root document" do
    assert {:ok, %Document{path: "/", content: "root body", revision: 1}} =
             SqliteDocuments.put("/", "root body", nil, 0)

    assert {:ok, %Document{path: "/", content: "root body", revision: 1}} =
             SqliteDocuments.fetch("/")

    assert {:ok, %{rows: [["__root__", "/"]]}} =
             Unfinal.Repo.query(
               "SELECT namespace, relative_path FROM documents WHERE path = ?1",
               ["/"],
               timeout: 5_000
             )
  end

  test "put cannot recreate a path reserved by a move redirect" do
    assert {:ok, _document} = SqliteDocuments.put("/alpha/notes", "notes", nil, 0)
    assert :ok = SqliteDocuments.move("/alpha/notes", "/alpha/moved")

    assert {:error, :path_redirected} =
             SqliteDocuments.put("/alpha/notes", "stale edit", nil, 0)

    assert SqliteDocuments.resolve_path("/alpha/notes") == {:redirect, "/alpha/moved"}
  end
end
