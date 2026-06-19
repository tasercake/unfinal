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

  test "validates strict lowercase alphanumeric namespaces" do
    assert NamespaceStore.valid_namespace?("abc123")

    for namespace <- ["", "Abc", "abc-def", "abc_def", "abc def", "abc/def"] do
      refute NamespaceStore.valid_namespace?(namespace)
    end
  end

  test "claims one namespace per user and persists it", %{data_dir: data_dir} do
    user = %{"id" => "user-1", "email" => "one@example.com"}

    assert NamespaceStore.claim("alpha1", user) == :ok
    assert NamespaceStore.owner("alpha1") == %{user_id: "user-1", email: "one@example.com"}
    assert NamespaceStore.namespace_for_user("user-1") == "alpha1"

    assert File.read!(Path.join(data_dir, "namespaces.txt")) ==
             "alpha1\tuser-1\tone@example.com\n"

    NamespaceStore.clear()
    assert NamespaceStore.owner("alpha1") == %{user_id: "user-1", email: "one@example.com"}
  end

  test "prevents taken namespaces and second claims" do
    assert NamespaceStore.claim("alpha", %{"id" => "user-1", "email" => "one@example.com"}) == :ok

    assert NamespaceStore.claim("alpha", %{"id" => "user-2", "email" => "two@example.com"}) ==
             {:error, :taken}

    assert NamespaceStore.claim("beta", %{"id" => "user-1", "email" => "one@example.com"}) ==
             {:error, :already_claimed}
  end
end
