defmodule Unfinal.DocumentPath do
  @moduledoc """
  Validates public document path segments.
  """

  @type segment :: String.t()

  @segment_pattern ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/

  @spec valid_segment?(term()) :: boolean()
  def valid_segment?(segment) when is_binary(segment), do: Regex.match?(@segment_pattern, segment)
  def valid_segment?(_segment), do: false

  @spec valid_segments?(term()) :: boolean()
  def valid_segments?(segments) when is_list(segments),
    do: Enum.all?(segments, &valid_segment?/1)

  def valid_segments?(_segments), do: false
end
