defmodule Unfinal.S3ObjectStore do
  @moduledoc "S3-compatible object store using conditional PUT for CAS."

  @behaviour Unfinal.ContentStore

  alias Unfinal.ContentStore
  alias Unfinal.ContentStore.Document

  @impl true
  def get(path) do
    key = ContentStore.object_key(path)

    case request(:get, key, [], "") do
      {:ok, 200, headers, body} ->
        {:ok,
         %Document{
           path: path,
           content: body,
           etag: header(headers, "etag"),
           revision: revision(headers)
         }}

      {:ok, 404, _headers, _body} ->
        {:ok, ContentStore.missing(path)}

      {:ok, status, _headers, body} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def put(path, content, nil, 0) do
    put_conditional(path, content, [{"if-none-match", "*"}], 1)
  end

  def put(path, content, base_etag, base_revision) when is_binary(base_etag) do
    put_conditional(path, content, [{"if-match", base_etag}], base_revision + 1)
  end

  def put(path, _content, _base_etag, _base_revision), do: {:stale, latest!(path)}

  @impl true
  def clear, do: :ok

  defp put_conditional(path, content, condition_headers, next_revision) do
    key = ContentStore.object_key(path)

    headers = [
      {"x-amz-meta-unfinal-revision", Integer.to_string(next_revision)} | condition_headers
    ]

    case request(:put, key, headers, content) do
      {:ok, status, headers, _body} when status in [200, 201] ->
        {:ok,
         %Document{
           path: path,
           content: content,
           etag: header(headers, "etag"),
           revision: next_revision
         }}

      {:ok, status, _headers, _body} when status in [409, 412] ->
        {:stale, latest!(path)}

      {:ok, status, _headers, body} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp latest!(path) do
    case get(path) do
      {:ok, doc} ->
        doc

      {:error, reason} ->
        raise "failed to read latest document after stale write: #{inspect(reason)}"
    end
  end

  defp request(method, key, headers, body) do
    config = config!()
    uri = URI.parse(config.endpoint)
    path = "/#{config.bucket}/#{key}"
    now = DateTime.utc_now()
    date = Calendar.strftime(now, "%Y%m%d")
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    payload_hash = sha256_hex(body)

    base_headers = [
      {"host", uri.host},
      {"x-amz-content-sha256", payload_hash},
      {"x-amz-date", amz_date}
    ]

    headers = base_headers ++ headers
    signed_headers = headers |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.join(";")

    canonical_headers =
      headers
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> String.downcase(k) <> ":" <> String.trim(to_string(v)) <> "\n" end)
      |> Enum.join()

    canonical_request =
      [
        method |> Atom.to_string() |> String.upcase(),
        path,
        "",
        canonical_headers,
        signed_headers,
        payload_hash
      ]
      |> Enum.join("\n")

    scope = "#{date}/#{config.region}/s3/aws4_request"

    string_to_sign =
      ["AWS4-HMAC-SHA256", amz_date, scope, sha256_hex(canonical_request)] |> Enum.join("\n")

    signature =
      hmac(signing_key(config.secret_access_key, date, config.region), string_to_sign)
      |> Base.encode16(case: :lower)

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{config.access_key_id}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

    url = URI.to_string(%{uri | path: path})

    http_headers =
      Enum.map([{"authorization", authorization} | headers], fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    :inets.start()
    :ssl.start()

    req = {String.to_charlist(url), http_headers, ~c"text/plain; charset=utf-8", body}

    result =
      case method do
        :get ->
          :httpc.request(:get, {String.to_charlist(url), http_headers}, [], body_format: :binary)

        :put ->
          :httpc.request(:put, req, [], body_format: :binary)
      end

    case result do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok, status, normalize_headers(response_headers), response_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp config! do
    config = Application.get_env(:unfinal, :s3, [])

    %{
      bucket: configured!(config, :bucket, "UNFINAL_S3_BUCKET"),
      endpoint: configured!(config, :endpoint, "UNFINAL_S3_ENDPOINT"),
      access_key_id: configured!(config, :access_key_id, "UNFINAL_S3_ACCESS_KEY_ID"),
      secret_access_key: configured!(config, :secret_access_key, "UNFINAL_S3_SECRET_ACCESS_KEY"),
      region: Keyword.get(config, :region) || System.get_env("UNFINAL_S3_REGION", "auto")
    }
  end

  defp configured!(config, key, env_name) do
    Keyword.get(config, key) || System.get_env(env_name) ||
      raise "environment variable #{env_name} is missing"
  end

  defp header(headers, name), do: Map.get(headers, String.downcase(name))

  defp revision(headers) do
    case header(headers, "x-amz-meta-unfinal-revision") do
      nil -> 0
      value -> String.to_integer(value)
    end
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {k, v} -> {k |> to_string() |> String.downcase(), to_string(v)} end)
  end

  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp signing_key(secret, date, region),
    do: hmac(hmac(hmac(hmac("AWS4" <> secret, date), region), "s3"), "aws4_request")
end
