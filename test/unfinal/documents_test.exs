defmodule Unfinal.DocumentsTest do
  use ExUnit.Case, async: false

  alias Unfinal.Documents

  setup do
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    Documents.clear()

    # Clean SQLite tables before each test
    Unfinal.Repo.query("DELETE FROM documents", [])
    Unfinal.Repo.query("DELETE FROM namespace_claims", [])

    on_exit(fn ->
      Documents.clear()
    end)
  end

  test "flush success persists and broadcasts latest content with metadata" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/queued"))

    assert :ok = Documents.queue_put("/queued", "two")

    assert_receive {:content_updated, "/queued", %{content: "two", revision: 1, etag: etag}}, 300
    assert is_binary(etag)
    assert Documents.get("/queued").content == "two"
  end

  test "queue_put persists empty and whitespace content instead of deleting" do
    Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic("/blank"))

    assert :ok = Documents.queue_put("/blank", "existing")
    assert_receive {:content_updated, "/blank", %{content: "existing", revision: 1}}, 300

    assert :ok = Documents.queue_put("/blank", "   \n\t")
    assert_receive {:content_updated, "/blank", %{content: "   \n\t", revision: 2}}, 300

    assert :ok = Documents.queue_put("/blank", "")
    assert_receive {:content_updated, "/blank", %{content: "", revision: 3}}, 300
  end





end
