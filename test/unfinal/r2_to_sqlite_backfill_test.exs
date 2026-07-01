defmodule Unfinal.R2ToSQLiteBackfillTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Unfinal.ContentStore
  alias Unfinal.ContentStore.Document
  alias Unfinal.FakeObjectStore
  alias Unfinal.R2ToSQLiteBackfill
  alias Unfinal.Repo

  setup do
    Application.put_env(:unfinal, :object_store_adapter, FakeObjectStore)
    FakeObjectStore.ensure_started()
    FakeObjectStore.clear()

    # Clean SQLite tables before each test
    Repo.query("DELETE FROM documents", [])
    Repo.query("DELETE FROM namespace_claims", [])

    on_exit(fn ->
      FakeObjectStore.clear()
      Repo.query("DELETE FROM documents", [])
      Repo.query("DELETE FROM namespace_claims", [])
      Application.put_env(:unfinal, :object_store_adapter, FakeObjectStore)
    end)

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp seed_namespace_index(content) do
    FakeObjectStore.put_object("indexes/namespaces.txt", content)
  end

  defp seed_page_index(namespace, ndjson_content) do
    FakeObjectStore.put_object("indexes/namespaces/#{namespace}.ndjson", ndjson_content)
  end

  defp seed_document(path, content, revision \\ 1) do
    # Use ContentStore.put via FakeObjectStore to create a readable document
    doc = %Document{
      path: path,
      content: content,
      etag: "etag-#{System.unique_integer([:positive])}",
      revision: revision,
      write_id: "write-#{System.unique_integer([:positive])}"
    }

    # Directly put into FakeObjectStore agent keyed by path
    Agent.update(FakeObjectStore, &Map.put(&1, path, doc))
  end

  defp query_document(path) do
    case Repo.query(
           "SELECT path, namespace, relative_path, content, revision, updated_at FROM documents WHERE path = ?1",
           [path]
         ) do
      {:ok, %{rows: [row]}} -> row
      {:ok, %{rows: []}} -> nil
    end
  end

  defp query_namespace_claims do
    case Repo.query(
           "SELECT namespace, email, claimed_at FROM namespace_claims ORDER BY namespace",
           []
         ) do
      {:ok, %{rows: rows}} -> rows
    end
  end

  defp run_silently(opts) do
    parent = self()

    log =
      capture_log(fn ->
        result = R2ToSQLiteBackfill.run(opts)
        send(parent, {:backfill_result, result})
      end)

    result =
      receive do
        {:backfill_result, r} -> r
      after
        1_000 -> flunk("backfill did not send result")
      end

    {log, result}
  end

  # ── Empty/missing namespace index ───────────────────────────────────────

  describe "empty/missing namespace index" do
    test "produces zero counts and no fatal error" do
      # FakeObjectStore is clear, so get_object returns {:error, :not_found}
      assert {:ok, report} = R2ToSQLiteBackfill.run(mode: :commit)

      assert report["namespace_rows_valid"] == 0
      assert report["namespace_rows_invalid"] == []
      assert report["documents_expected"] == 0
      assert report["documents_fetched"] == 0
      assert report["documents_inserted"] == 0
      assert report["namespace_claims_inserted"] == 0
      assert report["missing_indexed_documents"] == []
    end
  end

  # ── Path reconstruction ─────────────────────────────────────────────────

  describe "path reconstruction" do
    test "reconstructs /<namespace> for root path /" do
      seed_namespace_index("mynamespace\tuser@example.com\n")

      seed_page_index(
        "mynamespace",
        Jason.encode!(%{path: "/", updated_at: "2025-01-15T10:30:00Z"}) <> "\n"
      )

      seed_document("/mynamespace", "home page content")

      assert {:ok, report} = R2ToSQLiteBackfill.run(mode: :commit)

      assert report["documents_expected"] == 1
      assert report["documents_fetched"] == 1
      assert report["documents_inserted"] == 1

      row = query_document("/mynamespace")
      assert row != nil
      assert ["/mynamespace", "mynamespace", "/", "home page content", _, _] = row
    end

    test "reconstructs /<namespace>/<relative> for non-root paths" do
      seed_namespace_index("mynamespace\tuser@example.com\n")

      seed_page_index(
        "mynamespace",
        Jason.encode!(%{path: "/notes", updated_at: "2025-01-15T10:30:00Z"}) <> "\n"
      )

      seed_document("/mynamespace/notes", "notes content")

      assert {:ok, report} = R2ToSQLiteBackfill.run(mode: :commit)

      assert report["documents_fetched"] == 1
      row = query_document("/mynamespace/notes")
      assert row != nil
      assert ["/mynamespace/notes", "mynamespace", "/notes", "notes content", _, _] = row
    end
  end

  # ── Document key uses object_key/1 ──────────────────────────────────────

  describe "expected document key" do
    test "uses Unfinal.ContentStore.object_key/1" do
      seed_namespace_index("mynamespace\tuser@example.com\n")

      seed_page_index(
        "mynamespace",
        Jason.encode!(%{path: "/", updated_at: "2025-01-15T10:30:00Z"}) <> "\n"
      )

      # Don't seed the actual document — it will be missing
      expected_key = ContentStore.object_key("/mynamespace")

      {_, {:ok, report}} = run_silently(mode: :commit)

      assert [%{expected_key: ^expected_key}] = report["missing_indexed_documents"]
    end
  end

  # ── Commit inserts namespace claims and document rows ───────────────────

  describe "commit" do
    test "inserts namespace claims and document rows" do
      seed_namespace_index("mynamespace\tuser@example.com\n")

      seed_page_index(
        "mynamespace",
        Jason.encode!(%{path: "/", updated_at: "2025-01-15T10:30:00Z"}) <> "\n"
      )

      seed_document("/mynamespace", "content", 1)

      assert {:ok, report} = R2ToSQLiteBackfill.run(mode: :commit)

      assert report["namespace_claims_inserted"] == 1
      assert report["documents_inserted"] == 1

      # Verify SQLite rows
      claims = query_namespace_claims()
      assert length(claims) == 1
      assert [["mynamespace", "user@example.com", _claimed_at]] = claims

      row = query_document("/mynamespace")
      assert row != nil
      assert ["/mynamespace", "mynamespace", "/", "content", 1, _updated_at] = row
    end
  end

  # ── Idempotency ─────────────────────────────────────────────────────────

  describe "idempotency" do
    test "running commit twice does not duplicate or corrupt rows" do
      seed_namespace_index("mynamespace\tuser@example.com\n")

      seed_page_index(
        "mynamespace",
        Jason.encode!(%{path: "/", updated_at: "2025-01-15T10:30:00Z"}) <> "\n"
      )

      seed_document("/mynamespace", "content", 1)

      # First run
      assert {:ok, report1} = R2ToSQLiteBackfill.run(mode: :commit)
      assert report1["namespace_claims_inserted"] == 1
      assert report1["documents_inserted"] == 1

      # Second run — same data
      assert {:ok, report2} = R2ToSQLiteBackfill.run(mode: :commit)
      assert report2["namespace_claims_inserted"] == 0
      assert report2["namespace_claims_existing"] == 1
      assert report2["documents_inserted"] == 0

      # SQLite state unchanged — exactly one namespace claim, one document
      assert length(query_namespace_claims()) == 1

      assert ["/mynamespace", "mynamespace", "/", "content", 1, _] =
               query_document("/mynamespace")
    end
  end

  # ── Dry-run ─────────────────────────────────────────────────────────────

  describe "dry-run" do
    test "computes expected counts but leaves SQLite unchanged" do
      seed_namespace_index("mynamespace\tuser@example.com\n")

      seed_page_index(
        "mynamespace",
        Jason.encode!(%{path: "/", updated_at: "2025-01-15T10:30:00Z"}) <> "\n"
      )

      seed_document("/mynamespace", "content", 1)

      assert {:ok, report} = R2ToSQLiteBackfill.run(mode: :dry_run)

      assert report["mode"] == "dry_run"
      assert report["namespace_rows_valid"] == 1
      assert report["documents_expected"] == 1
      assert report["documents_fetched"] == 1

      # SQLite must be unchanged
      assert query_document("/mynamespace") == nil
      assert query_namespace_claims() == []
    end
  end

  # ── Guarded SQLite writes ───────────────────────────────────────────────

  describe "guarded SQLite writes" do
    test "does not overwrite existing SQLite document with greater updated_at" do
      # Seed SQLite with a "newer" row
      Repo.query(
        "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        ["/mynamespace", "mynamespace", "/", "existing-newer", 2, "2025-06-01T00:00:00Z"]
      )

      # R2 index has an older document
      seed_namespace_index("mynamespace\tuser@example.com\n")

      seed_page_index(
        "mynamespace",
        Jason.encode!(%{path: "/", updated_at: "2025-01-01T00:00:00Z"}) <> "\n"
      )

      seed_document("/mynamespace", "backfill-content", 1)

      assert {:ok, report} = R2ToSQLiteBackfill.run(mode: :commit)

      assert report["documents_skipped_newer"] == ["/mynamespace"]
      assert report["documents_inserted"] == 0
      assert report["documents_updated"] == 0

      # Existing row must be preserved
      assert ["/mynamespace", "mynamespace", "/", "existing-newer", 2, "2025-06-01T00:00:00Z"] =
               query_document("/mynamespace")
    end

    test "does not overwrite existing SQLite document with greater revision" do
      # Seed SQLite with revision 5
      Repo.query(
        "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        ["/mynamespace", "mynamespace", "/", "existing-rev5", 5, "2025-01-01T00:00:00Z"]
      )

      # R2 index has revision 3 with a newer timestamp
      seed_namespace_index("mynamespace\tuser@example.com\n")

      seed_page_index(
        "mynamespace",
        Jason.encode!(%{path: "/", updated_at: "2025-06-01T00:00:00Z"}) <> "\n"
      )

      seed_document("/mynamespace", "backfill-content", 3)

      assert {:ok, report} = R2ToSQLiteBackfill.run(mode: :commit)

      assert report["documents_skipped_newer"] == ["/mynamespace"]
      assert report["documents_inserted"] == 0

      # Existing row preserved — higher revision wins
      assert ["/mynamespace", _, _, "existing-rev5", 5, _] = query_document("/mynamespace")
    end

    test "existing document with equal timestamp and revision is not updated idempotently" do
      # Seed SQLite with matching revision and timestamp
      Repo.query(
        "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        ["/mynamespace", "mynamespace", "/", "same-content", 2, "2025-01-15T10:30:00Z"]
      )

      seed_namespace_index("mynamespace\tuser@example.com\n")

      seed_page_index(
        "mynamespace",
        Jason.encode!(%{path: "/", updated_at: "2025-01-15T10:30:00Z"}) <> "\n"
      )

      seed_document("/mynamespace", "same-content", 2)

      assert {:ok, report} = R2ToSQLiteBackfill.run(mode: :commit)

      # Equal revision + timestamp → no update
      assert report["documents_inserted"] == 0
      assert report["documents_updated"] == 0
      assert length(report["documents_skipped_newer"]) <= 1

      # Existing row unchanged
      assert ["/mynamespace", _, _, "same-content", 2, "2025-01-15T10:30:00Z"] =
               query_document("/mynamespace")
    end
  end

  # ── Missing indexed documents ───────────────────────────────────────────

  describe "missing indexed documents" do
    test "is reported and not inserted" do
      seed_namespace_index("mynamespace\tuser@example.com\n")

      seed_page_index(
        "mynamespace",
        Jason.encode!(%{path: "/", updated_at: "2025-01-15T10:30:00Z"}) <> "\n"
      )

      # Don't seed the actual document — it will be missing from ContentStore

      {_, {:ok, report}} = run_silently(mode: :commit)

      assert report["documents_expected"] == 1
      assert report["documents_fetched"] == 0
      assert report["documents_inserted"] == 0

      assert [%{full_path: "/mynamespace", namespace: "mynamespace"}] =
               report["missing_indexed_documents"]

      # No row inserted into SQLite
      assert query_document("/mynamespace") == nil
    end
  end

  # ── Malformed namespace/page lines ──────────────────────────────────────

  describe "malformed namespace/page lines" do
    test "are reported and skipped without failing" do
      seed_namespace_index(
        "validns\tok@example.com\n" <>
          "bad-email\tnot-an-email\n" <>
          "no-tab-separator\n" <>
          "UPPERCASE\tok@example.com\n"
      )

      seed_page_index(
        "validns",
        Jason.encode!(%{path: "/", updated_at: "2025-01-15T10:30:00Z"}) <>
          "\n" <>
          "not-json-at-all\n" <>
          Jason.encode!(%{path: "/", updated_at: "not-a-timestamp"}) <>
          "\n" <>
          Jason.encode!(%{path: "/ok", updated_at: "2025-01-16T10:00:00Z"}) <>
          "\n" <>
          Jason.encode!(%{path: "no-leading-slash", updated_at: "2025-01-15T10:30:00Z"}) <> "\n"
      )

      seed_document("/validns", "root content")
      seed_document("/validns/ok", "page content")

      assert {:ok, report} = R2ToSQLiteBackfill.run(mode: :commit)

      # 3 invalid namespace lines (bad-email, no-tab, UPPERCASE)
      assert length(report["namespace_rows_invalid"]) == 3
      # Only "validns" is valid
      assert report["namespace_rows_valid"] == 1

      # 3 invalid page lines (not-json, bad-timestamp, no-leading-slash)
      assert length(report["page_index_entries_invalid"]) == 3
      # 2 valid page entries (/ and /ok)
      assert report["page_index_entries_valid"] == 2

      # Valid documents were still processed
      assert report["documents_fetched"] == 2
      assert report["documents_inserted"] == 2
      assert report["missing_indexed_documents"] == []
    end
  end

  # ── Adapter/Repo errors ─────────────────────────────────────────────────

  describe "adapter errors" do
    test "returns error on namespace index read failure" do
      Application.put_env(:unfinal, :object_store_adapter, Unfinal.FailingObjectStore)

      assert {:error, {:namespace_index_read_failed, :read_failed}} =
               R2ToSQLiteBackfill.run(mode: :commit)
    end
  end
end
