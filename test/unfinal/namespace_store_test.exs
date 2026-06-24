defmodule Unfinal.NamespaceStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.NamespaceStore

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    Unfinal.ContentStore.clear()
    NamespaceStore.clear()

    on_exit(fn ->
      NamespaceStore.clear()
      Unfinal.ContentStore.clear()
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

    :sys.replace_state(NamespaceStore, fn _state -> %{} end)
    assert NamespaceStore.owner("alpha1") == %{email: "one@example.com"}
  end

  test "prevents taken namespaces and second claims by same email" do
    assert NamespaceStore.claim("alpha", %{"id" => "user-1", "email" => "one@example.com"}) == :ok

    assert NamespaceStore.claim("alpha", %{"id" => "user-2", "email" => "two@example.com"}) ==
             {:error, :taken}

    assert NamespaceStore.claim("beta", %{"id" => "user-2", "email" => "one@example.com"}) ==
             {:error, :already_claimed}
  end
end
