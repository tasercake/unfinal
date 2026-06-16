defmodule Synopticon.ContentStoreTest do
  use ExUnit.Case, async: false

  alias Synopticon.ContentStore

  setup do
    ContentStore.set("")
    :ok
  end

  test "stores latest content in memory" do
    assert ContentStore.get() == ""

    ContentStore.set("hello")

    assert ContentStore.get() == "hello"
  end

  test "broadcasts content changes" do
    Phoenix.PubSub.subscribe(Synopticon.PubSub, ContentStore.topic())

    ContentStore.set("live")

    assert_receive {:content_updated, "live"}
  end
end
