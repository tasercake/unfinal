defmodule Unfinal.NamespaceStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.NamespaceStore

  setup do
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
    assert :ok = NamespaceStore.claim("alpha", %{"email" => "one@example.com"})

    assert {:error, :taken} =
             NamespaceStore.claim("alpha", %{"email" => "two@example.com"})

    assert {:error, :already_claimed} =
             NamespaceStore.claim("beta", %{"email" => "one@example.com"})
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["alpha"])
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE email = ?1", ["one@example.com"])
  end

  test "claim persists namespace and email to SQLite" do
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

  test "duplicate namespace returns :taken" do
    assert :ok = NamespaceStore.claim("taken-ns", %{"email" => "first@example.com"})

    assert {:error, :taken} =
             NamespaceStore.claim("taken-ns", %{"email" => "second@example.com"})
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["taken-ns"])
  end

  test "duplicate email returns :already_claimed" do
    assert :ok = NamespaceStore.claim("ns-a", %{"email" => "dup@example.com"})

    assert {:error, :already_claimed} =
             NamespaceStore.claim("ns-b", %{"email" => "dup@example.com"})
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["ns-a"])
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["ns-b"])
  end

  test "owner and namespace_for_email read from SQLite" do
    assert :ok = NamespaceStore.claim("email-ns", %{"email" => "findme@example.com"})
    assert NamespaceStore.namespace_for_email("findme@example.com") == "email-ns"
    assert NamespaceStore.namespace_for_email("notfound@example.com") == nil
    assert NamespaceStore.owner("email-ns") == %{email: "findme@example.com"}
    assert NamespaceStore.owner("nonexistent") == nil
    assert NamespaceStore.taken?("email-ns") == true
    assert NamespaceStore.taken?("nonexistent") == false
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["email-ns"])
  end

  test "reads come from SQLite" do
    # Insert directly into SQLite — should be visible via NamespaceStore
    Unfinal.Repo.query(
      "INSERT INTO namespace_claims(namespace, email, claimed_at) VALUES (?1, ?2, ?3)",
      ["direct-insert", "direct@example.com", "2025-01-01T00:00:00Z"]
    )

    assert NamespaceStore.owner("direct-insert") == %{email: "direct@example.com"}
    assert NamespaceStore.namespace_for_email("direct@example.com") == "direct-insert"
    assert NamespaceStore.taken?("direct-insert") == true
  after
    Unfinal.Repo.query("DELETE FROM namespace_claims WHERE namespace = ?1", ["direct-insert"])
  end
end
