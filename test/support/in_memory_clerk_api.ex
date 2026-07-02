defmodule InMemoryClerkAPI do
  @moduledoc """
  Test stub for the Clerk API used by `mix unfinal.migrate_namespace_user_ids`.

  Injected via application config:
      config :unfinal, :clerk_api_module, InMemoryClerkAPI

  Setup in tests:
      InMemoryClerkAPI.set_responses(%{
        "alice@example.com" => "user_alice",
        "bob@example.com" => "user_bob"
      })

  Clear between tests:
      InMemoryClerkAPI.clear()
  """

  @app :unfinal
  @key :in_memory_clerk_api_responses

  @doc """
  Store email → user_id mappings for the current test.
  """
  def set_responses(responses) when is_map(responses) do
    Application.put_env(@app, @key, responses)
  end

  @doc """
  Clear all stored responses.
  """
  def clear do
    Application.delete_env(@app, @key)
  end

  @doc """
  Fetch a Clerk user_id for the given email.

  Returns the stored user_id for the email, or raises if no mapping exists.
  Raises with `:api_error` if the stored value is `:error` (for testing error paths).
  Ignores the `secret_key` — it's accepted for interface compatibility.
  """
  def fetch_clerk_user_id!(_secret_key, email) do
    responses = Application.get_env(@app, @key, %{})

    case Map.get(responses, email) do
      nil ->
        raise "InMemoryClerkAPI: no response configured for email: #{email}"

      :error ->
        raise "InMemoryClerkAPI: simulated API error for email: #{email}"

      user_id when is_binary(user_id) ->
        user_id
    end
  end
end
