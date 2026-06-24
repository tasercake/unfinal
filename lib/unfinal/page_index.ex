defmodule Unfinal.PageIndex do
  @moduledoc "Namespace page index stored as NDJSON."

  alias Unfinal.DocumentPath
  alias Unfinal.ObjectIndex

  @type entry :: %{path: String.t(), updated_at: String.t()}

  @spec list(String.t()) :: [entry()]
  def list(namespace) when is_binary(namespace) do
    namespace
    |> key()
    |> ObjectIndex.get()
    |> case do
      {:ok, content} -> parse(content)
      {:error, :not_found} -> []
      {:error, _reason} -> []
    end
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  @spec upsert(String.t(), String.t(), DateTime.t()) :: :ok | {:error, term()}
  def upsert(namespace, path, %DateTime{} = updated_at)
      when is_binary(namespace) and is_binary(path) do
    if DocumentPath.valid_segment?(namespace) and valid_relative_path?(path) do
      entries =
        namespace
        |> list()
        |> Enum.reject(&(&1.path == path))

      write(namespace, [%{path: path, updated_at: DateTime.to_iso8601(updated_at)} | entries])
    else
      {:error, :invalid}
    end
  end

  @spec parse(String.t()) :: [entry()]
  defp parse(content) do
    content
    |> String.split(["\r\n", "\n", "\r"], trim: true)
    |> Enum.flat_map(fn line ->
      with {:ok, %{"path" => path, "updated_at" => updated_at}} <- Jason.decode(line),
           true <- valid_relative_path?(path),
           {:ok, _dt, 0} <- DateTime.from_iso8601(updated_at) do
        [%{path: path, updated_at: updated_at}]
      else
        _ -> []
      end
    end)
  end

  @spec write(String.t(), [entry()]) :: :ok | {:error, term()}
  defp write(namespace, entries) do
    content =
      entries
      |> Enum.sort_by(& &1.updated_at, :desc)
      |> Enum.map_join("", fn entry ->
        Jason.encode!(%{path: entry.path, updated_at: entry.updated_at}) <> "\n"
      end)

    ObjectIndex.put(key(namespace), content)
  end

  @spec valid_relative_path?(term()) :: boolean()
  defp valid_relative_path?("/" <> rest) when rest != "" do
    rest |> String.split("/") |> DocumentPath.valid_segments?()
  end

  defp valid_relative_path?(_path), do: false

  @spec key(String.t()) :: String.t()
  defp key(namespace), do: "indexes/namespaces/#{namespace}.ndjson"
end
