defmodule Unfinal.NamespaceStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.NamespaceStore

  setup do
    previous_data_dir = System.get_env("UNFINAL_DATA_DIR")

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "unfinal-namespace-store-#{System.unique_integer([:positive])}"
      )

    System.put_env("UNFINAL_DATA_DIR", data_dir)
    File.rm_rf!(data_dir)
    NamespaceStore.clear()

    on_exit(fn ->
      NamespaceStore.clear()
      File.rm_rf!(data_dir)

      if previous_data_dir do
        System.put_env("UNFINAL_DATA_DIR", previous_data_dir)
      else
        System.delete_env("UNFINAL_DATA_DIR")
      end
    end)

    %{data_dir: data_dir}
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

  test "claims one namespace per email and persists namespace tab email", %{data_dir: data_dir} do
    user = %{"id" => "user-1", "email" => "one@example.com"}

    assert NamespaceStore.claim("alpha1", user) == :ok
    assert NamespaceStore.owner("alpha1") == %{email: "one@example.com"}
    assert NamespaceStore.namespace_for_email("one@example.com") == "alpha1"

    assert File.read!(Path.join(data_dir, "namespaces.txt")) ==
             "alpha1\tone@example.com\n"

    NamespaceStore.clear()
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
