defmodule Unfinal.PageIndex do
  @moduledoc "Live namespace page index facade."

  alias Unfinal.DocumentPath

  @topic_prefix "page_index:"

  @type entry :: %{path: String.t(), updated_at: String.t()}

  @spec topic(String.t()) :: String.t()
  def topic(namespace), do: @topic_prefix <> Base.url_encode64(namespace, padding: false)

  @spec list(String.t()) :: [entry()]
  def list(namespace) when is_binary(namespace) do
    if valid_namespace?(namespace) and storage_enabled?() do
      Unfinal.SqliteDocuments.list_namespace(namespace)
    else
      []
    end
  end

  @spec upsert(String.t(), String.t(), DateTime.t()) :: :ok | {:error, term()}
  def upsert(namespace, path, %DateTime{} = updated_at)
      when is_binary(namespace) and is_binary(path) do
    if valid_namespace?(namespace) and DocumentPath.valid_relative_path?(path) do
      if storage_enabled?() do
        updated_at_iso = DateTime.to_iso8601(updated_at)

        case Unfinal.SqliteDocuments.touch_page(namespace, path, updated_at_iso) do
          :ok ->
            entries = Unfinal.SqliteDocuments.list_namespace(namespace)

            Phoenix.PubSub.broadcast(Unfinal.PubSub, topic(namespace), {
              :page_index_updated,
              namespace,
              entries
            })

            :ok

          {:error, reason} ->
            {:error, reason}
        end
      else
        :ok
      end
    else
      {:error, :invalid}
    end
  end

  @spec clear() :: :ok
  def clear do
    :ok
  end

  defp valid_namespace?(namespace), do: DocumentPath.valid_segment?(namespace)

  defp storage_enabled?, do: Application.get_env(:unfinal, :storage_mode) == :sqlite
end
