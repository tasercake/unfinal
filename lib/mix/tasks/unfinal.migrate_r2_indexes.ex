defmodule Mix.Tasks.Unfinal.MigrateR2Indexes do
  @moduledoc """
  This task is retired after SQLite cutover.

  R2 indexes are read-only archive. Use `mix unfinal.migrate_r2_to_sqlite --allow-r2-archive-read`
  to backfill from archived R2 indexes into SQLite.
  """

  use Mix.Task

  @shortdoc "Retired — use unfinal.migrate_r2_to_sqlite --allow-r2-archive-read instead"

  @impl true
  def run(_args) do
    Mix.raise(
      "unfinal.migrate_r2_indexes is retired after SQLite cutover; " <>
        "R2 is read-only archive. " <>
        "Use `mix unfinal.migrate_r2_to_sqlite --allow-r2-archive-read` instead."
    )
  end
end
