defmodule Unfinal.R2Index do
  @moduledoc """
  Centralized R2 index serialization and parsing.

  Provides byte-compatible NDJSON (page index) and TSV (namespace index) formats
  used by R2 storage reads, so that PageIndex and NamespaceStore can become SQLite
  facades without losing rollback mirrors.

  ## Formats

  **Page index (NDJSON):** One JSON object per line with `path` and `updated_at`
  (ISO8601), sorted newest-first by `updated_at`.

  **Namespace index (TSV):** `namespace<TAB>email\n`, sorted by namespace.
  """

  alias Unfinal.ObjectIndex

  @type page_entry :: %{path: String.t(), updated_at: String.t()}

  # ─── Page Index (NDJSON) ───

  @doc """
  Serialize page entries to NDJSON content.

  Each line is a JSON object with `path` and `updated_at` (ISO8601),
  sorted newest-first by `updated_at`. Trailing newline after each line.
  """
  @spec serialize_page_index([page_entry()]) :: String.t()
  def serialize_page_index(entries) when is_list(entries) do
    entries
    |> Enum.sort_by(& &1.updated_at, :desc)
    |> Enum.map_join("", fn entry ->
      Jason.encode!(%{path: entry.path, updated_at: entry.updated_at}) <> "\n"
    end)
  end

  @doc """
  Parse NDJSON page index content into a list of entries.

  Each line must be a JSON object with `path` and `updated_at` (valid ISO8601).
  Invalid lines are silently skipped. Results are sorted newest-first by `updated_at`.
  """
  @spec parse_page_ndjson(String.t()) :: [page_entry()]
  def parse_page_ndjson(content) when is_binary(content) do
    content
    |> String.split(["\r\n", "\n", "\r"], trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"path" => path, "updated_at" => updated_at}} ->
          [%{path: path, updated_at: updated_at}]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  @doc """
  Write page index NDJSON to R2 via ObjectIndex.
  """
  @spec write_page_index(String.t(), [page_entry()]) :: :ok | {:error, term()}
  def write_page_index(namespace, entries) when is_binary(namespace) and is_list(entries) do
    content = serialize_page_index(entries)
    ObjectIndex.put(page_index_key(namespace), content)
  end

  @doc """
  R2 object key for a namespace's page index.
  """
  @spec page_index_key(String.t()) :: String.t()
  def page_index_key(namespace), do: "indexes/namespaces/#{namespace}.ndjson"

  # ─── Namespace Index (TSV) ───

  @doc """
  Serialize namespace claims to TSV content.

  Each line is `namespace<TAB>email\n`, sorted alphabetically by namespace.
  Accepts either a map `%{namespace => %{email: email}}` or a list of
  `{namespace, email}` tuples (export/task convenience).
  """
  @spec serialize_namespace_index(map() | [{String.t(), String.t()}]) :: String.t()
  def serialize_namespace_index(claims) when is_list(claims) do
    claims
    |> Enum.sort_by(fn {namespace, _email} -> namespace end)
    |> Enum.map_join("", fn {namespace, email} ->
      "#{namespace}\t#{email}\n"
    end)
  end

  def serialize_namespace_index(claims) when is_map(claims) do
    claims
    |> Enum.sort_by(fn {namespace, _owner} -> namespace end)
    |> Enum.map_join("", fn {namespace, owner} ->
      "#{namespace}\t#{owner.email}\n"
    end)
  end

  @doc """
  Parse TSV namespace index content into a list of `{namespace, email}` tuples.
  Invalid lines are silently skipped.
  """
  @spec parse_namespace_tsv(String.t()) :: [{String.t(), String.t()}]
  def parse_namespace_tsv(content) when is_binary(content) do
    content
    |> String.split(["\r\n", "\n", "\r"], trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [namespace, email] -> [{namespace, String.trim(email)}]
        _ -> []
      end
    end)
  end

  @doc """
  Write namespace index TSV to R2 via ObjectIndex.
  """
  @spec write_namespace_index(%{String.t() => %{email: String.t()}}) :: :ok | {:error, term()}
  def write_namespace_index(claims) when is_map(claims) do
    content = serialize_namespace_index(claims)
    ObjectIndex.put(namespace_index_key(), content)
  end

  @doc """
  R2 object key for the namespace index.
  """
  @spec namespace_index_key() :: String.t()
  def namespace_index_key, do: "indexes/namespaces.txt"
end
