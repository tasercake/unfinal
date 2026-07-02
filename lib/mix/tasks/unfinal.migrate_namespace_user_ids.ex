defmodule Mix.Tasks.Unfinal.MigrateNamespaceUserIds do
  @moduledoc """
  Populate user_id in namespace_claims from Clerk API.

  Runs after `mix ecto.migrate` in the deploy pipeline.
  Idempotent: skips rows where user_id IS NOT NULL.

  Requires CLERK_SECRET_KEY environment variable.

  Pre-flight safety: Before running any UPDATEs, the task fetches user_id
  for ALL rows and detects duplicate user_id values. If two different emails
  resolve to the same Clerk user_id, the task aborts with a clear error
  explaining which namespaces conflict and how to resolve them.
  """
  use Mix.Task

  @shortdoc "Populate user_id in namespace_claims from Clerk API"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start", ["--no-start"])
    {:ok, _} = Application.ensure_all_started(:unfinal)

    clerk_secret_key =
      System.get_env("CLERK_SECRET_KEY") ||
        raise "CLERK_SECRET_KEY environment variable is required for user_id migration"

    {:ok, %{rows: rows}} =
      Unfinal.Repo.query(
        "SELECT namespace, email FROM namespace_claims WHERE user_id IS NULL",
        []
      )

    if rows == [] do
      Mix.shell().info("All namespace claims already have user_id. Nothing to migrate.")
    else
      Mix.shell().info("Pre-flight: fetching user_id for #{length(rows)} claims...")

      # Phase 1: Fetch all user_ids and detect duplicates before writing anything.
      # This prevents a cryptic MatchError on the UNIQUE constraint if two emails
      # resolve to the same Clerk user_id.
      resolved =
        Enum.map(rows, fn [namespace, email] ->
          user_id = fetch_clerk_user_id!(clerk_secret_key, email)
          {namespace, email, user_id}
        end)

      # Group by user_id to detect collisions
      duplicates =
        resolved
        |> Enum.group_by(fn {_ns, _email, uid} -> uid end)
        |> Enum.filter(fn {_uid, entries} -> length(entries) > 1 end)

      if duplicates != [] do
        Mix.shell().error("""

        ═══════════════════════════════════════════════════════════════════
        FATAL: Duplicate user_id detected — migration aborted, no rows updated.
        ═══════════════════════════════════════════════════════════════════

        Two or more namespace_claims rows have different emails that resolve
        to the same Clerk user_id. The UNIQUE constraint on user_id would
        cause the second UPDATE to fail with a constraint violation.

        Conflicts:
        """)

        Enum.each(duplicates, fn {uid, entries} ->
          Mix.shell().error("  user_id: #{uid}")
          Enum.each(entries, fn {ns, email, _uid} ->
            Mix.shell().error("    - namespace=#{ns}, email=#{email}")
          end)
        end)

        Mix.shell().error("""

        Resolution options:
          1. Delete the duplicate namespace_claim row that should NOT be associated
             with this user_id:
               DELETE FROM namespace_claims WHERE namespace = '<duplicate_namespace>';

          2. Or, if both namespaces should belong to the same user, decide which one
             to keep and delete the other.

          3. Re-run the deploy after resolving the conflict. The migration is idempotent.
        """)

        raise "Duplicate user_id collision detected. Aborting migration — no rows updated."
      end

      # Phase 2: No duplicates — safe to UPDATE
      Mix.shell().info("Pre-flight passed. No duplicate user_ids. Updating #{length(rows)} rows...")

      Enum.each(resolved, fn {namespace, _email, user_id} ->
        case Unfinal.Repo.query(
               "UPDATE namespace_claims SET user_id = ?1 WHERE namespace = ?2",
               [user_id, namespace]
             ) do
          {:ok, %{num_rows: 1}} ->
            Mix.shell().info("  Updated #{namespace} -> user_id=#{user_id}")

          {:ok, %{num_rows: 0}} ->
            # Row was deleted between SELECT and UPDATE (unlikely but safe to skip)
            Mix.shell().info("  Skipped #{namespace} — row no longer exists")

          {:error, reason} ->
            raise "Failed to update #{namespace}: #{inspect(reason)}"
        end
      end)

      Mix.shell().info("Migration complete. #{length(rows)} claims updated.")
    end
  end

  defp fetch_clerk_user_id!(secret_key, email) do
    url = "https://api.clerk.com/v1/users?email_address=#{URI.encode(email)}"
    url_charlist = String.to_charlist(url)

    headers = [
      {'authorization', String.to_charlist("Bearer #{secret_key}")},
      {'content-type', 'application/json'}
    ]

    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {url_charlist, headers}, [ssl: ssl_opts()], body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _resp_headers, body}} ->
        case Jason.decode(body) do
          {:ok, [%{"id" => user_id} | _]} when is_binary(user_id) and user_id != "" ->
            user_id

          {:ok, []} ->
            raise "Clerk API returned no user for email: #{email}"

          {:ok, other} ->
            raise "Clerk API returned unexpected response for #{email}: #{inspect(other)}"

          {:error, reason} ->
            raise "Failed to parse Clerk API response for #{email}: #{inspect(reason)}"
        end

      {:ok, {{_version, status, reason}, _resp_headers, body}} ->
        raise "Clerk API returned #{status} #{reason} for email #{email}: #{body}"

      {:error, reason} ->
        raise "HTTP request to Clerk API failed for #{email}: #{inspect(reason)}"
    end
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :certifi.cacerts(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
