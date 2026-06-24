defmodule Unfinal.R2IndexMigration do
  @moduledoc """
  One-shot migration helper for old namespace TSV files and known page paths.

  Page paths must come from a manifest because existing document object keys are hashed
  and cannot be reversed back to original paths.
  """

  alias Unfinal.DocumentPath
  alias Unfinal.ObjectIndex
  alias Unfinal.PageIndex

  @namespace_index_key "indexes/namespaces.txt"

  @type option ::
          {:namespaces_path, String.t()}
          | {:manifest_path, String.t() | nil}
          | {:dry_run?, boolean()}
  @type summary :: %{
          namespaces_written: non_neg_integer(),
          pages_written: non_neg_integer(),
          dry_run?: boolean()
        }

  @spec run([option()]) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    namespaces_path = Keyword.get(opts, :namespaces_path, default_namespaces_path())
    manifest_path = Keyword.get(opts, :manifest_path)
    dry_run? = Keyword.get(opts, :dry_run?, false)

    with {:ok, old_namespaces} <- read_namespaces_file(namespaces_path),
         {:ok, existing_namespaces} <- read_namespace_index(),
         {:ok, manifest_entries} <- read_manifest(manifest_path),
         merged_namespaces <- Map.merge(old_namespaces, existing_namespaces),
         :ok <- maybe_write_namespaces(merged_namespaces, dry_run?),
         :ok <- maybe_write_pages(manifest_entries, dry_run?) do
      {:ok,
       %{
         namespaces_written: map_size(merged_namespaces),
         pages_written: length(manifest_entries),
         dry_run?: dry_run?
       }}
    end
  end

  @spec default_namespaces_path() :: String.t()
  def default_namespaces_path do
    System.get_env("UNFINAL_DATA_DIR", "./.data")
    |> Path.join("namespaces.txt")
  end

  @spec parse_namespace_tsv(String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def parse_namespace_tsv(content) when is_binary(content) do
    content
    |> lines_with_numbers()
    |> Enum.reduce_while({:ok, %{}}, fn {line, line_number}, {:ok, acc} ->
      case parse_namespace_line(line, line_number) do
        {:ok, namespace, email} -> {:cont, {:ok, Map.put(acc, namespace, email)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec parse_manifest_tsv(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def parse_manifest_tsv(content) when is_binary(content) do
    content
    |> lines_with_numbers()
    |> Enum.reduce_while({:ok, []}, fn {line, line_number}, {:ok, acc} ->
      case parse_manifest_line(line, line_number) do
        {:ok, namespace, path} -> {:cont, {:ok, [{namespace, path} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read_namespaces_file(String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  defp read_namespaces_file(path) do
    case File.read(path) do
      {:ok, content} -> parse_namespace_tsv(content)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:read_namespaces_failed, path, reason}}
    end
  end

  @spec read_namespace_index() :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  defp read_namespace_index do
    case ObjectIndex.get(@namespace_index_key) do
      {:ok, content} -> parse_namespace_tsv(content)
      {:error, :not_found} -> {:ok, %{}}
      {:error, reason} -> {:error, {:read_namespace_index_failed, reason}}
    end
  end

  @spec read_manifest(String.t() | nil) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  defp read_manifest(nil), do: {:ok, []}

  defp read_manifest(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> parse_manifest_tsv(content)
      {:error, reason} -> {:error, {:read_manifest_failed, path, reason}}
    end
  end

  @spec maybe_write_namespaces(%{String.t() => String.t()}, boolean()) :: :ok | {:error, term()}
  defp maybe_write_namespaces(_namespaces, true), do: :ok

  defp maybe_write_namespaces(namespaces, false) do
    content =
      namespaces
      |> Enum.sort_by(fn {namespace, _email} -> namespace end)
      |> Enum.map_join("", fn {namespace, email} -> "#{namespace}\t#{email}\n" end)

    ObjectIndex.put(@namespace_index_key, content)
  end

  @spec maybe_write_pages([{String.t(), String.t()}], boolean()) :: :ok | {:error, term()}
  defp maybe_write_pages(_entries, true), do: :ok

  defp maybe_write_pages(entries, false) do
    now = DateTime.utc_now()

    Enum.reduce_while(entries, :ok, fn {namespace, path}, :ok ->
      case PageIndex.upsert(namespace, path, now) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:write_page_index_failed, namespace, path, reason}}}
      end
    end)
  end

  @spec lines_with_numbers(String.t()) :: [{String.t(), pos_integer()}]
  defp lines_with_numbers(content) do
    content
    |> String.split(["\r\n", "\n", "\r"], trim: true)
    |> Enum.with_index(1)
  end

  @spec parse_namespace_line(String.t(), pos_integer()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  defp parse_namespace_line(line, line_number) do
    case String.split(line, "\t", parts: 3) do
      [namespace, email] ->
        if DocumentPath.valid_segment?(namespace) and String.contains?(email, "@") do
          {:ok, namespace, email}
        else
          {:error, {:invalid_namespace_row, line_number}}
        end

      _parts ->
        {:error, {:invalid_namespace_row, line_number}}
    end
  end

  @spec parse_manifest_line(String.t(), pos_integer()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  defp parse_manifest_line(line, line_number) do
    case String.split(line, "\t", parts: 3) do
      [namespace, path] ->
        if DocumentPath.valid_segment?(namespace) and valid_relative_path?(path) do
          {:ok, namespace, path}
        else
          {:error, {:invalid_manifest_row, line_number}}
        end

      _parts ->
        {:error, {:invalid_manifest_row, line_number}}
    end
  end

  @spec valid_relative_path?(term()) :: boolean()
  defp valid_relative_path?("/"), do: true

  defp valid_relative_path?("/" <> rest) when rest != "" do
    rest |> String.split("/") |> DocumentPath.valid_segments?()
  end

  defp valid_relative_path?(_path), do: false
end
