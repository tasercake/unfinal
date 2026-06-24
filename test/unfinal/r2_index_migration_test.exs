defmodule Unfinal.R2IndexMigrationTest do
  use ExUnit.Case, async: true

  alias Unfinal.R2IndexMigration

  test "parse_manifest_tsv accepts namespace root pages" do
    assert R2IndexMigration.parse_manifest_tsv("tanay\t/\ntanay\t/edtech\n") ==
             {:ok, [{"tanay", "/"}, {"tanay", "/edtech"}]}
  end
end
