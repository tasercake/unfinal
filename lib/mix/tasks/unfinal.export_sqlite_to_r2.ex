defmodule Mix.Tasks.Unfinal.ExportSqliteToR2 do
  @shortdoc "Retired — R2 is read-only archive after Phase 6 cutover"
  @moduledoc """
  This task is retired after Phase 6 cutover.

  R2 is read-only archive; application R2 writes are disabled.
  If a future rollback to R2-primary is needed, the S3ObjectStore
  write functions must first be re-enabled in a prior phase.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.raise(
      "unfinal.export_sqlite_to_r2 is retired after Phase 6 cutover; " <>
        "R2 is read-only archive. Application R2 writes are disabled."
    )
  end
end
