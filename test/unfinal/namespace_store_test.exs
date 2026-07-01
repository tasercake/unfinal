defmodule Unfinal.NamespaceStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Unfinal.NamespaceStore
  alias Unfinal.StorageModeHelper

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    Unfinal.Documents.clear()
    NamespaceStore.clear()

    # Clean SQLite tables before each test
    Unfinal.Repo.query("DELETE FROM namespace_claims", [])

    on_exit(fn ->
      NamespaceStore.clear()
      Unfinal.Documents.clear()
      # Restore default repo in case test overrode it
      Application.put_env(:unfinal, :sqlite_shadow_repo, Unfinal.Repo)
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

  test "claims one namespace per email and persists namespace tab email" do
    user = %{"id" => "user-1", "email" => "one@example.com"}

    assert NamespaceStore.claim("alpha1", user) == :ok
    assert NamespaceStore.owner("alpha1") == %{email: "one@example.com"}
    assert NamespaceStore.namespace_for_email("one@example.com") == "alpha1"

    assert Unfinal.ObjectIndex.get("indexes/namespaces.txt") ==
             {:ok, "alpha1\tone@example.com\n"}

    :sys.replace_state(NamespaceStore, fn _state -> %{sqlite_primary: false, r2_state: %{}} end)
    assert NamespaceStore.owner("alpha1") == %{email: "one@example.com"}
  end

  test "prevents taken namespaces and second claims by same email" do
    assert NamespaceStore.claim("alpha", %{"id" => "user-1", "email" => "one@example.com"}) == :ok

    assert NamespaceStore.claim("alpha", %{"id" => "user-2", "email" => "two@example.com"}) ==
             {:error, :taken}

    assert NamespaceStore.claim("beta", %{"id" => "user-2", "email" => "one@example.com"}) ==
             {:error, :already_claimed}
  end

  test "claim writes old R2 namespace index primary and shadows SQLite claim" do
    assert NamespaceStore.claim("alpha1", %{"email" => "one@example.com"}) == :ok

    # R2 index is the primary store
    assert Unfinal.ObjectIndex.get("indexes/namespaces.txt") ==
             {:ok, "alpha1\tone@example.com\n"}

    # SQLite namespace_claims row was shadow-inserted
    {:ok, %{rows: rows}} =
      Unfinal.Repo.query(
        "SELECT namespace, email FROM namespace_claims WHERE namespace = ?1",
        ["alpha1"]
      )

    assert [["alpha1", "one@example.com"]] = rows
  end

  test "sqlite namespace shadow failure does not fail successful R2 claim" do
    Application.put_env(:unfinal, :sqlite_shadow_repo, Unfinal.FailingSQLiteShadowRepo)

    log =
      capture_log(fn ->
        assert NamespaceStore.claim("alpha", %{"email" => "alpha@example.com"}) == :ok
      end)

    # R2/index object still exists
    {:ok, content} = Unfinal.ObjectIndex.get("indexes/namespaces.txt")
    assert content =~ "alpha"

    assert log =~ "sqlite shadow namespace claim insert failed for alpha"
  end

  test "namespace reads still come from R2/index primary" do
    # Seed SQLite namespace_claims directly without going through NamespaceStore
    Unfinal.Repo.query(
      "INSERT INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)",
      ["sqlite-only", "sqlite@example.com", DateTime.to_iso8601(~U[2025-01-01 00:00:00Z])]
    )

    # Do NOT seed R2 index — reads should still come from R2/index primary
    assert NamespaceStore.namespace_for_email("sqlite@example.com") == nil
    assert NamespaceStore.owner("sqlite-only") == nil
  end

  # -- SQLite-primary mode tests --

  test "claim inserts into SQLite in SQLite-primary mode" do
    StorageModeHelper.set_storage_mode!(:sqlite)

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
    StorageModeHelper.set_storage_mode!(:r2)
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["sqlite-ns"])
  end

  test "duplicate namespace returns :taken in SQLite-primary mode" do
    StorageModeHelper.set_storage_mode!(:sqlite)

    assert :ok = NamespaceStore.claim("taken-ns", %{"email" => "first@example.com"})
    assert {:error, :taken} = NamespaceStore.claim("taken-ns", %{"email" => "second@example.com"})
  after
    StorageModeHelper.set_storage_mode!(:r2)
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["taken-ns"])
  end

  test "duplicate email returns :already_claimed in SQLite-primary mode" do
    StorageModeHelper.set_storage_mode!(:sqlite)

    assert :ok = NamespaceStore.claim("ns-a", %{"email" => "dup@example.com"})

    assert {:error, :already_claimed} =
             NamespaceStore.claim("ns-b", %{"email" => "dup@example.com"})
  after
    StorageModeHelper.set_storage_mode!(:r2)
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["ns-a"])
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["ns-b"])
  end

  test "namespace_for_email queries SQLite in SQLite-primary mode" do
    StorageModeHelper.set_storage_mode!(:sqlite)

    assert :ok = NamespaceStore.claim("email-ns", %{"email" => "findme@example.com"})
    assert NamespaceStore.namespace_for_email("findme@example.com") == "email-ns"
    assert NamespaceStore.namespace_for_email("notfound@example.com") == nil
  after
    StorageModeHelper.set_storage_mode!(:r2)
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["email-ns"])
  end
end
