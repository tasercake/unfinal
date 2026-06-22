defmodule Unfinal.S3ObjectStoreTest do
  use ExUnit.Case, async: false

  alias Unfinal.S3ObjectStore

  setup do
    previous_config = Application.get_env(:unfinal, :s3)

    on_exit(fn ->
      if previous_config do
        Application.put_env(:unfinal, :s3, previous_config)
      else
        Application.delete_env(:unfinal, :s3)
      end
    end)

    :ok
  end

  test "successful put returns document with per-write write_id without extra get" do
    parent = self()

    Application.put_env(:unfinal, :s3,
      request_fun: fn
        :put, _key, headers, "hello" ->
          send(parent, {:put_headers, headers})
          {:ok, 200, %{"etag" => "etag-1"}, ""}

        :get, _key, _headers, _body ->
          flunk("successful put must not issue get")
      end
    )

    assert {:ok, doc} = S3ObjectStore.put("/notes", "hello", nil, 0)
    assert doc.content == "hello"
    assert doc.etag == "etag-1"
    assert doc.revision == 1
    assert is_binary(doc.write_id)

    assert_received {:put_headers, headers}
    assert {"x-amz-meta-unfinal-write-id", doc.write_id} in headers
  end

  test "commit-then-transport-error reconciles latest matching write_id as success" do
    parent = self()

    Application.put_env(:unfinal, :s3,
      request_fun: fn
        :put, _key, headers, "hello" ->
          write_id = List.keyfind(headers, "x-amz-meta-unfinal-write-id", 0) |> elem(1)
          send(parent, {:write_id, write_id})
          {:error, :timeout}

        :get, _key, _headers, _body ->
          assert_received {:write_id, write_id}

          {:ok, 200,
           %{
             "etag" => "etag-committed",
             "x-amz-meta-unfinal-revision" => "1",
             "x-amz-meta-unfinal-write-id" => write_id
           }, "hello"}
      end
    )

    assert {:ok, doc} = S3ObjectStore.put("/notes", "hello", nil, 0)
    assert doc.content == "hello"
    assert doc.etag == "etag-committed"
    assert doc.revision == 1
    assert is_binary(doc.write_id)
  end

  test "transport error with different latest write_id stays ambiguous" do
    Application.put_env(:unfinal, :s3,
      request_fun: fn
        :put, _key, _headers, "hello" ->
          {:error, :timeout}

        :get, _key, _headers, _body ->
          {:ok, 200,
           %{
             "etag" => "etag-other",
             "x-amz-meta-unfinal-revision" => "2",
             "x-amz-meta-unfinal-write-id" => "other-write"
           }, "other"}
      end
    )

    assert {:error, {:ambiguous_put_unresolved, put: :timeout, latest: latest}} =
             S3ObjectStore.put("/notes", "hello", nil, 0)

    assert latest.content == "other"
    assert latest.write_id == "other-write"
  end
end
