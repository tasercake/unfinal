defmodule Unfinal.SQLiteShadowTest do
  use ExUnit.Case, async: false

  alias Unfinal.ContentStore.Document
  alias Unfinal.SQLiteShadow

  setup do
    # Clean SQLite tables before each test
    Unfinal.Repo.query("DELETE FROM documents", [])
    Unfinal.Repo.query("DELETE FROM namespace_claims", [])

    on_exit(fn ->
      Unfinal.Repo.query("DELETE FROM documents", [])
      Unfinal.Repo.query("DELETE FROM namespace_claims", [])
      # Restore default repo in case test overrode it
      Application.delete_env(:unfinal, :sqlite_shadow_repo)
    end)

    :ok
  end

  # Helper to create a fixed DateTime for deterministic tests
  defp fixed_dt do
    ~U[2025-01-15 10:30:00Z]
  end

  defp later_dt do
    ~U[2025-01-15 11:30:00Z]
  end

  defp make_doc(path, opts \\ []) do
    %Document{
      path: path,
      content: Keyword.get(opts, :content, "default"),
      etag: Keyword.get(opts, :etag, "etag-1"),
      revision: Keyword.get(opts, :revision, 1),
      write_id: Keyword.get(opts, :write_id, "write-1")
    }
  end

  defp query_row(path) do
    case Unfinal.Repo.query(
           "SELECT path, namespace, relative_path, content, revision, updated_at FROM documents WHERE path = ?1",
           [path]
         ) do
      {:ok, %{rows: [row]}} -> row
      {:ok, %{rows: []}} -> nil
    end
  end

  defp query_namespace_claims do
    case Unfinal.Repo.query(
           "SELECT namespace, email, claimed_at FROM namespace_claims ORDER BY namespace",
           []
         ) do
      {:ok, %{rows: rows}} -> rows
    end
  end

  # ── Document tests ──────────────────────────────────────────────────────

  describe "upsert_document/2" do
    test "inserts namespace root document" do
      doc = make_doc("/alpha", content: "home", revision: 1)
      dt = fixed_dt()

      assert :ok = SQLiteShadow.upsert_document(doc, dt)

      assert ["/alpha", "alpha", "/", "home", 1, iso_dt] = query_row("/alpha")
      assert iso_dt == DateTime.to_iso8601(dt)
    end

    test "inserts nested namespace document" do
      doc = make_doc("/alpha/notes", content: "hello", revision: 1)
      dt = fixed_dt()

      assert :ok = SQLiteShadow.upsert_document(doc, dt)

      assert ["/alpha/notes", "alpha", "/notes", "hello", 1, _] = query_row("/alpha/notes")
    end

    test "ignores global root and invalid paths" do
      dt = fixed_dt()

      # Global root
      doc_root = make_doc("/", content: "root")
      assert :ignored = SQLiteShadow.upsert_document(doc_root, dt)
      assert nil == query_row("/")

      # Invalid namespace (uppercase)
      doc_upper = make_doc("/Alpha/page", content: "bad")
      assert :ignored = SQLiteShadow.upsert_document(doc_upper, dt)
      assert nil == query_row("/Alpha/page")

      # Empty relative path after namespace
      doc_empty = make_doc("/alpha/", content: "bad")
      assert :ignored = SQLiteShadow.upsert_document(doc_empty, dt)
      assert nil == query_row("/alpha/")
    end

    test "does not overwrite newer revision" do
      dt = fixed_dt()

      # Seed with revision 2
      seed_sql = """
      INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """

      Unfinal.Repo.query(seed_sql, [
        "/alpha",
        "alpha",
        "/",
        "newer",
        2,
        DateTime.to_iso8601(dt)
      ])

      # Attempt to overwrite with revision 1 and later timestamp
      doc = make_doc("/alpha", content: "older", revision: 1)
      assert :ok = SQLiteShadow.upsert_document(doc, later_dt())

      # Row should remain unchanged
      assert ["/alpha", "alpha", "/", "newer", 2, _] = query_row("/alpha")
    end

    test "does not overwrite same revision with older updated_at" do
      later = later_dt()
      earlier = fixed_dt()

      # Seed with revision 2 and later timestamp
      seed_sql = """
      INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """

      Unfinal.Repo.query(seed_sql, [
        "/alpha",
        "alpha",
        "/",
        "newer",
        2,
        DateTime.to_iso8601(later)
      ])

      # Attempt to overwrite with same revision but older timestamp
      doc = make_doc("/alpha", content: "older-ts", revision: 2)
      assert :ok = SQLiteShadow.upsert_document(doc, earlier)

      # Row should remain unchanged
      assert ["/alpha", "alpha", "/", "newer", 2, _] = query_row("/alpha")
    end

    test "overwrites lower revision with higher revision" do
      dt = fixed_dt()

      # Seed with revision 1
      seed_sql = """
      INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """

      Unfinal.Repo.query(seed_sql, [
        "/alpha",
        "alpha",
        "/",
        "old",
        1,
        DateTime.to_iso8601(dt)
      ])

      # Overwrite with revision 2
      doc = make_doc("/alpha", content: "new", revision: 2)
      assert :ok = SQLiteShadow.upsert_document(doc, later_dt())

      assert ["/alpha", "alpha", "/", "new", 2, _] = query_row("/alpha")
    end

    test "returns error instead of raising on repo failure" do
      Application.put_env(:unfinal, :sqlite_shadow_repo, Unfinal.FailingSQLiteShadowRepo)

      doc = make_doc("/alpha", content: "fail", revision: 1)
      assert {:error, :sqlite_shadow_failed} = SQLiteShadow.upsert_document(doc, fixed_dt())
    end
  end

  # ── Namespace claim tests ───────────────────────────────────────────────

  describe "insert_namespace_claim/3" do
    test "inserts and is idempotent for same row" do
      dt = fixed_dt()

      assert :ok = SQLiteShadow.insert_namespace_claim("alpha", "one@example.com", dt)
      assert :ok = SQLiteShadow.insert_namespace_claim("alpha", "one@example.com", dt)

      rows = query_namespace_claims()
      assert length(rows) == 1
      assert [["alpha", "one@example.com", _]] = rows
    end

    test "reports conflict without overwriting" do
      dt = fixed_dt()

      # Seed original claim
      seed_sql = """
      INSERT OR IGNORE INTO namespace_claims(namespace, email, claimed_at)
      VALUES (?1, ?2, ?3)
      """

      Unfinal.Repo.query(seed_sql, ["alpha", "one@example.com", DateTime.to_iso8601(dt)])

      # Attempt conflicting claim with different email
      assert {:error, {:namespace_claim_conflict, "alpha", "two@example.com", _rows}} =
               SQLiteShadow.insert_namespace_claim("alpha", "two@example.com", later_dt())

      # Original row must remain unchanged
      rows = query_namespace_claims()
      assert length(rows) == 1
      assert [["alpha", "one@example.com", _]] = rows
    end

    test "returns error instead of raising on repo failure" do
      Application.put_env(:unfinal, :sqlite_shadow_repo, Unfinal.FailingSQLiteShadowRepo)

      assert {:error, :sqlite_shadow_failed} =
               SQLiteShadow.insert_namespace_claim("alpha", "one@example.com", fixed_dt())
    end
  end
end
