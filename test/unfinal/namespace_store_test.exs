defmodule Unfinal.NamespaceStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.NamespaceStore
  alias Unfinal.StorageModeHelper

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    StorageModeHelper.set_storage_mode!(:sqlite)

    # Ensure NamespaceStore GenServer is in SQLite-primary mode
    :sys.replace_state(NamespaceStore, fn _state ->
      %{sqlite_primary: true, r2_state: %{}}
    end)

    Unfinal.Documents.clear()
    NamespaceStore.clear()

    # Clean SQLite tables before each test
    Unfinal.Repo.query("DELETE FROM namespace_claims", [])

    on_exit(fn ->
      NamespaceStore.clear()
      Unfinal.Documents.clear()
      StorageModeHelper.set_storage_mode!(:sqlite)
    end)

    :ok
  end

  # Helper: switch NamespaceStore to R2 mode for legacy tests
  defp switch_to_r2_mode! do
    StorageModeHelper.set_storage_mode!(:r2)
    :sys.replace_state(NamespaceStore, fn _state -> %{sqlite_primary: false, r2_state: %{}} end)
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
    assert :ok = NamespaceStore.claim("alpha", %{"email" => "one@example.com"})

    assert {:error, :taken} =
             NamespaceStore.claim("alpha", %{"email" => "two@example.com"})

    assert {:error, :already_claimed} =
             NamespaceStore.claim("beta", %{"email" => "one@example.com"})
  end

  test "claim in R2 mode does not crash despite ObjectIndex being read-only" do
    switch_to_r2_mode!()

    # claim succeeds (in-memory r2_state is updated; ObjectIndex write is a no-op)
    assert NamespaceStore.claim("alpha1", %{"email" => "one@example.com"}) == :ok
  after
    StorageModeHelper.set_storage_mode!(:sqlite)
  end

  # -- SQLite-primary mode tests --

  test "claim inserts into SQLite in SQLite-primary mode" do
    assert :ok = NamespaceStore.claim("sqlite-ns", %{"email" => "sqlite@example.com"})

    # Verify SQLite has the claim
    {:ok, %{rows: rows}} =
      Unfinal.Repo.query(
        "SELECT namespace, email FROM namespace_claims WHERE namespace = ?1",
        ["sqlite-ns"]
      )

    assert [["sqlite-ns", "sqlite@example.com"]] = rows

    # Verify owner lookup works
    assert NamespaceStore.owner("sqlite-ns") == %{email: "sqlite@example.com"}
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["sqlite-ns"])
  end

  test "duplicate namespace returns :taken in SQLite-primary mode" do
    assert :ok = NamespaceStore.claim("taken-ns", %{"email" => "first@example.com"})

    assert {:error, :taken} =
             NamespaceStore.claim("taken-ns", %{"email" => "second@example.com"})
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["taken-ns"])
  end

  test "duplicate email returns :already_claimed in SQLite-primary mode" do
    assert :ok = NamespaceStore.claim("ns-a", %{"email" => "dup@example.com"})

    assert {:error, :already_claimed} =
             NamespaceStore.claim("ns-b", %{"email" => "dup@example.com"})
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["ns-a"])
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["ns-b"])
  end

  test "namespace_for_email queries SQLite in SQLite-primary mode" do
    assert :ok = NamespaceStore.claim("email-ns", %{"email" => "findme@example.com"})
    assert NamespaceStore.namespace_for_email("findme@example.com") == "email-ns"
    assert NamespaceStore.namespace_for_email("notfound@example.com") == nil
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["email-ns"])
  end

  test "SQLite-primary claim writes only to SQLite, no R2 index created" do
    assert :ok = NamespaceStore.claim("only-sqlite", %{"email" => "only@example.com"})

    # Verify SQLite has the claim
    assert NamespaceStore.owner("only-sqlite") == %{email: "only@example.com"}

    # Verify no R2 namespace index was created
    assert {:error, _} = Unfinal.ObjectIndex.get("indexes/namespaces.txt")
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["only-sqlite"])
  end

  test "SQLite-primary claim and lookup are idempotent and isolated" do
    # Claim a namespace
    assert :ok = NamespaceStore.claim("iso-ns", %{"email" => "iso@example.com"})

    # Owner lookup
    assert NamespaceStore.owner("iso-ns") == %{email: "iso@example.com"}
    assert NamespaceStore.owner("nonexistent") == nil

    # Email lookup
    assert NamespaceStore.namespace_for_email("iso@example.com") == "iso-ns"
    assert NamespaceStore.taken?("iso-ns") == true
    assert NamespaceStore.taken?("nonexistent") == false

    # Verify no R2 mirror was triggered
    assert {:error, _} = Unfinal.ObjectIndex.get("indexes/namespaces.txt")
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["iso-ns"])
  end
end
