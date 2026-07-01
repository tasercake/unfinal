defmodule Mix.Tasks.MigrateR2ToSqliteTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Unfinal.FakeObjectStore
  alias Unfinal.Repo

  setup do
    Application.put_env(:unfinal, :object_store_adapter, FakeObjectStore)
    FakeObjectStore.ensure_started()
    FakeObjectStore.clear()

    # Clean SQLite tables before each test
    Repo.query("DELETE FROM documents", [])
    Repo.query("DELETE FROM namespace_claims", [])

    on_exit(fn ->
      FakeObjectStore.clear()
      Repo.query("DELETE FROM documents", [])
      Repo.query("DELETE FROM namespace_claims", [])
      Application.put_env(:unfinal, :object_store_adapter, FakeObjectStore)
    end)

    :ok
  end

  # ── CLI mode validation ─────────────────────────────────────────────────

  describe "CLI mode validation" do
    test "raises when both --dry-run and --commit are passed" do
      assert_raise Mix.Error, ~r/cannot pass both --dry-run and --commit/, fn ->
        Mix.Tasks.Unfinal.MigrateR2ToSqlite.run(["--dry-run", "--commit"])
      end
    end

    test "raises on invalid options" do
      assert_raise Mix.Error, ~r/invalid/, fn ->
        Mix.Tasks.Unfinal.MigrateR2ToSqlite.run(["--unknown-flag"])
      end
    end
  end

  # ── Default dry-run ─────────────────────────────────────────────────────

  describe "default dry-run" do
    test "defaults to dry-run when no flags are passed" do
      # Empty FakeObjectStore — no namespace index, zero counts, no error
      output =
        capture_io(fn ->
          Mix.Tasks.Unfinal.MigrateR2ToSqlite.run([])
        end)

      assert output =~ "R2 to SQLite backfill complete"
      assert output =~ "dry_run"
    end
  end

  # ── Fatal errors ────────────────────────────────────────────────────────

  describe "fatal errors" do
    test "adapter read failure raises Mix.raise" do
      Application.put_env(:unfinal, :object_store_adapter, Unfinal.FailingObjectStore)

      assert_raise Mix.Error, ~r/R2 to SQLite backfill failed/, fn ->
        Mix.Tasks.Unfinal.MigrateR2ToSqlite.run(["--commit"])
      end
    end
  end
end
