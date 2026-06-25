defmodule Unfinal.PageIndexTest do
  use ExUnit.Case, async: false

  alias Unfinal.Documents
  alias Unfinal.PageIndex

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    Documents.clear()

    on_exit(fn ->
      Documents.clear()
    end)

    :ok
  end

  test "upserts namespace-relative paths and lists newest first" do
    assert PageIndex.list("alpha") == []

    assert :ok = PageIndex.upsert("alpha", "/", ~U[2026-06-23 00:00:00Z])
    assert :ok = PageIndex.upsert("alpha", "/notes", ~U[2026-06-24 00:00:00Z])
    assert :ok = PageIndex.upsert("alpha", "/ideas", ~U[2026-06-25 00:00:00Z])
    assert :ok = PageIndex.upsert("alpha", "/notes", ~U[2026-06-26 00:00:00Z])

    assert PageIndex.list("alpha") == [
             %{path: "/notes", updated_at: "2026-06-26T00:00:00Z"},
             %{path: "/ideas", updated_at: "2026-06-25T00:00:00Z"},
             %{path: "/", updated_at: "2026-06-23T00:00:00Z"}
           ]
  end

  test "ignores malformed ndjson lines" do
    assert :ok =
             Unfinal.ObjectIndex.put(
               "indexes/namespaces/alpha.ndjson",
               "bad\n{\"path\":\"/\",\"updated_at\":\"2026-06-25T00:00:00Z\"}\n{\"path\":\"/ok\",\"updated_at\":\"2026-06-24T00:00:00Z\"}\n{}\n"
             )

    assert PageIndex.list("alpha") == [
             %{path: "/", updated_at: "2026-06-25T00:00:00Z"},
             %{path: "/ok", updated_at: "2026-06-24T00:00:00Z"}
           ]
  end
end
