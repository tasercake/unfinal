defmodule Unfinal.FailingSQLiteShadowRepo do
  @moduledoc false
  @spec query(String.t(), list(), keyword()) :: {:error, term()}
  def query(_sql, _params, _opts), do: {:error, :sqlite_shadow_failed}
end
