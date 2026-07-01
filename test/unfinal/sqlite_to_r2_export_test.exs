defmodule Unfinal.SqliteToR2ExportTest do
  use ExUnit.Case, async: false

  alias Unfinal.ContentStore
  alias Unfinal.FakeObjectStore
  alias Unfinal.LegacyR2Index
  alias Unfinal.ObjectIndex
  alias Unfinal.SQLiteCleanup

  setup do
    Application.put_env(:unfinal, :object_store_adapter, FakeObjectStore)
    FakeObjectStore.ensure_started()
    FakeObjectStore.clear()
    SQLiteCleanup.clear_all()

    # Route S3ObjectStore HTTP calls through FakeObjectStore
    original_s3 = Application.get_env(:unfinal, :s3, [])

    Application.put_env(:unfinal, :s3,
      request_fun: fn
        :put, key, _headers, body ->
          FakeObjectStore.put_object(key, body)
          {:ok, 200, %{}, ""}

        :get, key, _headers, _body ->
          case FakeObjectStore.get_object(key) do
            {:ok, content} -> {:ok, 200, %{}, content}
            {:error, _} -> {:ok, 404, %{}, ""}
          end
      end
    )

    on_exit(fn ->
      FakeObjectStore.clear()
      SQLiteCleanup.clear_all()
      Application.put_env(:unfinal, :s3, original_s3)
    end)
  end

  test "export writes namespace claims as TSV to R2" do
    # Seed SQLite with claims
    Unfinal.Repo.query(
      "INSERT INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)",
      ["alpha", "alpha@example.com", "2025-01-01T00:00:00Z"]
    )

    Unfinal.Repo.query(
      "INSERT INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)",
      ["beta", "beta@example.com", "2025-01-01T00:00:00Z"]
    )

    # Export
    Mix.Tasks.Unfinal.ExportSqliteToR2.run([])

    # Verify R2 has namespace index
    {:ok, content} = ObjectIndex.get("indexes/namespaces.txt")
    claims = LegacyR2Index.parse_namespace_tsv(content)
    assert {"alpha", "alpha@example.com"} in claims
    assert {"beta", "beta@example.com"} in claims
  end

  test "export writes page indexes as NDJSON to R2" do
    # Seed SQLite with documents
    Unfinal.Repo.query(
      "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ["/myns/page1", "myns", "/page1", "content1", 1, "2025-06-01T00:00:00Z"]
    )

    Unfinal.Repo.query(
      "INSERT INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)",
      ["myns", "my@example.com", "2025-01-01T00:00:00Z"]
    )

    # Export
    Mix.Tasks.Unfinal.ExportSqliteToR2.run([])

    # Verify R2 has page index
    {:ok, content} = ObjectIndex.get("indexes/namespaces/myns.ndjson")
    entries = LegacyR2Index.parse_page_ndjson(content)
    assert Enum.any?(entries, &(&1.path == "/page1"))
  end

  test "export writes document objects to R2" do
    # Seed SQLite with a document
    Unfinal.Repo.query(
      "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ["/myns/doc1", "myns", "/doc1", "hello world", 1, "2025-06-01T00:00:00Z"]
    )

    Unfinal.Repo.query(
      "INSERT INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)",
      ["myns", "my@example.com", "2025-01-01T00:00:00Z"]
    )

    # Export
    Mix.Tasks.Unfinal.ExportSqliteToR2.run([])

    # Verify R2 has the document object
    key = ContentStore.object_key("/myns/doc1")
    assert {:ok, "hello world"} = FakeObjectStore.get_object(key)
  end

  test "export is idempotent" do
    # Seed and export twice
    Unfinal.Repo.query(
      "INSERT INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ["/myns/doc1", "myns", "/doc1", "content", 1, "2025-06-01T00:00:00Z"]
    )

    Unfinal.Repo.query(
      "INSERT INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)",
      ["myns", "my@example.com", "2025-01-01T00:00:00Z"]
    )

    Mix.Tasks.Unfinal.ExportSqliteToR2.run([])
    Mix.Tasks.Unfinal.ExportSqliteToR2.run([])

    # Should still have correct data (no duplicates)
    {:ok, content} = ObjectIndex.get("indexes/namespaces.txt")
    claims = LegacyR2Index.parse_namespace_tsv(content)
    assert length(claims) == 1
  end
end
