defmodule Unfinal.PageIndexTest do
  use ExUnit.Case, async: false

  alias Unfinal.Documents
  alias Unfinal.PageIndex
  alias Unfinal.SQLiteCleanup

  setup do
    Application.put_env(:unfinal, :storage_mode, :sqlite)
    SQLiteCleanup.clear_all()
    PageIndex.clear()
    Documents.clear()

    on_exit(fn ->
      PageIndex.clear()
      Documents.clear()
      SQLiteCleanup.clear_all()
    end)

    :ok
  end

  # -- SQLite-primary mode tests --

  test "upserts namespace-relative paths and lists newest first" do
    assert PageIndex.list("alpha") == []

    assert :ok = PageIndex.upsert("alpha", "/", ~U[2026-06-23 00:00:00Z])
    assert :ok = PageIndex.upsert("alpha", "/notes", ~U[2026-06-24 00:00:00Z])
    assert :ok = PageIndex.upsert("alpha", "/ideas", ~U[2026-06-25 00:00:00Z])
    assert :ok = PageIndex.upsert("alpha", "/notes", ~U[2026-06-26 00:00:00Z])

    assert PageIndex.list("alpha") == [
             %{path: "/notes", updated_at: "2026-06-26T00:00:00Z"},
             %{path: "/ideas", updated_at: "2026-06-25T00:00:00Z"},
             %{path: "/", updated_at: "2026-06-23T00:00:00Z"}
           ]
  end

  test "list returns empty for invalid namespace" do
    assert PageIndex.list("Invalid-Namespace") == []
  end

  test "list sees newly upserted entries immediately" do
    assert :ok = PageIndex.upsert("alpha", "/fast", ~U[2026-06-26 00:00:00Z])
    assert PageIndex.list("alpha") == [%{path: "/fast", updated_at: "2026-06-26T00:00:00Z"}]
    assert PageIndex.list("beta") == []
  end

  test "list reads from SQLite" do
    # Insert document directly into SQLite
    Unfinal.Repo.query(
      "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ["/testns/page1", "testns", "/page1", "content", 0, "2025-01-01T00:00:00Z"]
    )

    entries = PageIndex.list("testns")
    assert length(entries) == 1
    assert hd(entries).path == "/page1"
  end

  test "upsert returns error for invalid path" do
    assert {:error, :invalid} =
             PageIndex.upsert("testns", "no-leading-slash", ~U[2025-06-01 00:00:00Z])
  end

  test "upsert writes to SQLite and broadcasts" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, PageIndex.topic("spy-ns"))

    assert :ok = PageIndex.upsert("spy-ns", "/page", ~U[2025-06-01 00:00:00Z])

    entries = PageIndex.list("spy-ns")
    assert length(entries) == 1
    assert hd(entries).path == "/page"

    assert_receive {:page_index_updated, "spy-ns", _entries}, 1_000
  end

  test "SQLite documents ARE listed by PageIndex.list" do
    # Seed SQLite documents table directly
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Unfinal.Repo.query(
      "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ["/alpha/onlyinsqlite", "alpha", "/onlyinsqlite", "content", 1, now]
    )

    entries = PageIndex.list("alpha")
    assert Enum.any?(entries, fn e -> e.path == "/onlyinsqlite" end)
  end
end
