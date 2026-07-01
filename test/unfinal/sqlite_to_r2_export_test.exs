defmodule Unfinal.SqliteToR2ExportTest do
  use ExUnit.Case, async: false

  test "export_sqlite_to_r2 raises retired message" do
    assert_raise Mix.Error, ~r/is retired after Phase 6 cutover/, fn ->
      Mix.Tasks.Unfinal.ExportSqliteToR2.run([])
    end
  end

  test "export_sqlite_to_r2 raises retired message even with --allow-r2-archive-write" do
    assert_raise Mix.Error, ~r/is retired after Phase 6 cutover/, fn ->
      Mix.Tasks.Unfinal.ExportSqliteToR2.run(["--allow-r2-archive-write"])
    end
  end
end
