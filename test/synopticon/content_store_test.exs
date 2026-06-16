defmodule Synopticon.ContentStoreTest do
  use ExUnit.Case, async: false

  alias Synopticon.ContentStore

  setup do
    previous_data_dir = System.get_env("SYNOPTICON_DATA_DIR")

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "synopticon-content-store-#{System.unique_integer([:positive])}"
      )

    System.put_env("SYNOPTICON_DATA_DIR", data_dir)
    ContentStore.clear()

    on_exit(fn ->
      ContentStore.clear()
      File.rm_rf!(data_dir)

      if previous_data_dir do
        System.put_env("SYNOPTICON_DATA_DIR", previous_data_dir)
      else
        System.delete_env("SYNOPTICON_DATA_DIR")
      end
    end)

    %{data_dir: data_dir}
  end

  test "paths are empty by default" do
    assert ContentStore.get("/") == ""
    assert ContentStore.get("/notes") == ""
  end

  test "stores latest content per path in memory" do
    ContentStore.set("/notes", "hello")
    ContentStore.set("/other", "world")

    assert ContentStore.get("/notes") == "hello"
    assert ContentStore.get("/other") == "world"
    assert ContentStore.get("/") == ""
  end

  test "broadcasts content changes only on path topic" do
    Phoenix.PubSub.subscribe(Synopticon.PubSub, ContentStore.topic("/notes"))

    ContentStore.set("/other", "ignored")
    ContentStore.set("/notes", "live")

    assert_receive {:content_updated, "/notes", "live"}
    refute_receive {:content_updated, "/other", "ignored"}
  end

  test "persists content to sha256 path files", %{data_dir: data_dir} do
    ContentStore.set("/notes", "saved")

    hash = :crypto.hash(:sha256, "/notes") |> Base.encode16(case: :lower)
    path = Path.join([data_dir, "documents", hash <> ".txt"])

    assert File.read!(path) == "saved"
  end

  test "loads persisted content after memory is cleared", %{data_dir: data_dir} do
    hash = :crypto.hash(:sha256, "/notes") |> Base.encode16(case: :lower)
    path = Path.join([data_dir, "documents", hash <> ".txt"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "from disk")

    assert ContentStore.get("/notes") == "from disk"

    File.write!(path, "changed on disk")
    assert ContentStore.get("/notes") == "from disk"
  end
end
