defmodule Unfinal.NamespaceStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.NamespaceStore

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    Application.put_env(:unfinal, :storage_mode, :sqlite)

    # Ensure NamespaceStore GenServer is in SQLite-primary mode
    :sys.replace_state(NamespaceStore, fn _state ->
      %{sqlite_primary: true}
    end)

    Unfinal.Documents.clear()
    NamespaceStore.clear()

    # Clean SQLite tables before each test
    Unfinal.Repo.query("DELETE FROM namespace_claims", [])

    on_exit(fn ->
      NamespaceStore.clear()
    end)

    :ok
  end

  test "validates strict lowercase alphanumeric hyphen namespaces" do
    for namespace <- ["alpha", "alpha1", "alpha-1"] do
      assert NamespaceStore.valid_namespace?(namespace)
    end

    for namespace <- [
          "",
          "Alpha",
          "alpha_beta",
          "alpha.beta",
          "alpha beta",
          "alpha/one",
          "-alpha",
          "alpha-",
          ".."
        ] do
      refute NamespaceStore.valid_namespace?(namespace)
    end
  end

  test "prevents taken namespaces and second claims by same email" do
    assert :ok = NamespaceStore.claim("alpha", %{"id" => "user_1", "email" => "one@example.com"})

    assert {:error, :taken} =
             NamespaceStore.claim("alpha", %{"id" => "user_2", "email" => "two@example.com"})

    assert {:error, :already_claimed} =
             NamespaceStore.claim("beta", %{"id" => "user_1", "email" => "one@example.com"})
  end

  # -- SQLite-primary mode tests --

  test "claim inserts into SQLite in SQLite-primary mode" do
    assert :ok = NamespaceStore.claim("sqlite-ns", %{"id" => "user_sqlite", "email" => "sqlite@example.com"})

    # Verify SQLite has the claim
    {:ok, %{rows: rows}} =
      Unfinal.Repo.query(
        "SELECT namespace, email FROM namespace_claims WHERE namespace = ?1",
        ["sqlite-ns"]
      )

    assert [["sqlite-ns", "sqlite@example.com"]] = rows

    # Verify owner lookup works
    assert NamespaceStore.owner("sqlite-ns") == %{user_id: "user_sqlite"}
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["sqlite-ns"])
  end

  test "duplicate namespace returns :taken in SQLite-primary mode" do
    assert :ok = NamespaceStore.claim("taken-ns", %{"id" => "user_first", "email" => "first@example.com"})

    assert {:error, :taken} =
             NamespaceStore.claim("taken-ns", %{"id" => "user_second", "email" => "second@example.com"})
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["taken-ns"])
  end

  test "duplicate email returns :already_claimed in SQLite-primary mode" do
    assert :ok = NamespaceStore.claim("ns-a", %{"id" => "user_dup", "email" => "dup@example.com"})

    assert {:error, :already_claimed} =
             NamespaceStore.claim("ns-b", %{"id" => "user_dup", "email" => "dup@example.com"})
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["ns-a"])
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["ns-b"])
  end

  test "namespace_for_email queries SQLite in SQLite-primary mode" do
    assert :ok = NamespaceStore.claim("email-ns", %{"id" => "user_findme", "email" => "findme@example.com"})
    assert NamespaceStore.namespace_for_user_id("user_findme") == "email-ns"
    assert NamespaceStore.namespace_for_user_id("notfound") == nil
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["email-ns"])
  end

  test "SQLite-primary claim writes only to SQLite, no R2 index created" do
    assert :ok = NamespaceStore.claim("only-sqlite", %{"id" => "user_only", "email" => "only@example.com"})

    # Verify SQLite has the claim
    assert NamespaceStore.owner("only-sqlite") == %{user_id: "user_only"}
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["only-sqlite"])
  end

  test "SQLite-primary claim and lookup are idempotent and isolated" do
    # Claim a namespace
    assert :ok = NamespaceStore.claim("iso-ns", %{"id" => "user_iso", "email" => "iso@example.com"})

    # Owner lookup
    assert NamespaceStore.owner("iso-ns") == %{user_id: "user_iso"}
    assert NamespaceStore.owner("nonexistent") == nil

    # User ID lookup
    assert NamespaceStore.namespace_for_user_id("user_iso") == "iso-ns"
    assert NamespaceStore.taken?("iso-ns") == true
    assert NamespaceStore.taken?("nonexistent") == false
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["iso-ns"])
  end
end
