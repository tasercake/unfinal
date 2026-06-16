defmodule Synopticon.ContentStoreTest do
  use ExUnit.Case, async: false

  alias Synopticon.ContentStore

  setup do
    ContentStore.clear()
    :ok
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
end
