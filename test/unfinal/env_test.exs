defmodule Unfinal.EnvTest do
  use ExUnit.Case, async: false

  setup do
    original_value = System.get_env("UNFINAL_EXAMPLE")

    on_exit(fn -> restore_env("UNFINAL_EXAMPLE", original_value) end)
  end

  test "load_dotenv reads local .env without overriding existing values" do
    dir =
      Path.join(System.tmp_dir!(), "unfinal-env-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "UNFINAL_EXAMPLE=from-dotenv\n")

    on_exit(fn -> File.rm_rf!(dir) end)
    System.delete_env("UNFINAL_EXAMPLE")

    assert :ok = Unfinal.Env.load_dotenv(dir)
    assert System.get_env("UNFINAL_EXAMPLE") == "from-dotenv"
  end

  test "load_and_configure only loads dotenv" do
    assert :ok = Unfinal.Env.load_and_configure!()
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
