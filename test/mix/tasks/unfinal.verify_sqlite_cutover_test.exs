defmodule Mix.Tasks.Unfinal.VerifySqliteCutoverTest do
  use ExUnit.Case, async: false

  alias Unfinal.FakeObjectStore
  alias Unfinal.ObjectIndex
  alias Unfinal.SQLiteCleanup

  setup do
    Application.put_env(:unfinal, :object_store_adapter, FakeObjectStore)
    FakeObjectStore.ensure_started()
    FakeObjectStore.clear()
    SQLiteCleanup.clear_all()

    on_exit(fn ->
      FakeObjectStore.clear()
      SQLiteCleanup.clear_all()
    end)
  end

  test "passes when R2 and SQLite are in sync" do
    # Seed both R2 and SQLite with matching data
    # R2 namespace index
    ObjectIndex.put("indexes/namespaces.txt", "alpha\talpha@example.com\n")

    # R2 page index
    ObjectIndex.put(
      "indexes/namespaces/alpha.ndjson",
      Jason.encode!(%{path: "/page1", updated_at: "2025-06-01T00:00:00Z"}) <> "\n"
    )

    # SQLite namespace claim
    Unfinal.Repo.query(
      "INSERT INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)",
      ["alpha", "alpha@example.com", "2025-01-01T00:00:00Z"]
    )

    # SQLite document
    Unfinal.Repo.query(
      "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ["/alpha/page1", "alpha", "/page1", "content", 1, "2025-06-01T00:00:00Z"]
    )

    # Should not raise
    Mix.Tasks.Unfinal.VerifySqliteCutover.run([])
  end

  test "fails when namespace claim is missing from SQLite" do
    # R2 has a namespace but SQLite doesn't
    ObjectIndex.put("indexes/namespaces.txt", "orphan\torphan@example.com\n")

    assert_raise Mix.Error, ~r/missing namespace/i, fn ->
      Mix.Tasks.Unfinal.VerifySqliteCutover.run([])
    end
  end

  test "fails when namespace owner email mismatches" do
    # R2 says alpha is owned by alpha@example.com
    ObjectIndex.put("indexes/namespaces.txt", "alpha\talpha@example.com\n")

    # SQLite says alpha is owned by different@example.com
    Unfinal.Repo.query(
      "INSERT INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)",
      ["alpha", "different@example.com", "2025-01-01T00:00:00Z"]
    )

    assert_raise Mix.Error, ~r/mismatch/i, fn ->
      Mix.Tasks.Unfinal.VerifySqliteCutover.run([])
    end
  end

  test "fails when indexed document is missing from SQLite" do
    # R2 has namespace + page index
    ObjectIndex.put("indexes/namespaces.txt", "alpha\talpha@example.com\n")

    ObjectIndex.put(
      "indexes/namespaces/alpha.ndjson",
      Jason.encode!(%{path: "/page1", updated_at: "2025-06-01T00:00:00Z"}) <> "\n"
    )

    # SQLite has namespace claim but NOT the document
    Unfinal.Repo.query(
      "INSERT INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)",
      ["alpha", "alpha@example.com", "2025-01-01T00:00:00Z"]
    )

    assert_raise Mix.Error, ~r/cutover verification failed/i, fn ->
      Mix.Tasks.Unfinal.VerifySqliteCutover.run([])
    end
  end

  test "passes when R2 namespace index is missing (no data to verify)" do
    # No R2 data at all — should pass
    Mix.Tasks.Unfinal.VerifySqliteCutover.run([])
  end
end
