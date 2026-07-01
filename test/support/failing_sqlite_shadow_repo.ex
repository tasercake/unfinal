defmodule Unfinal.FailingSQLiteShadowRepo do
  @moduledoc false
  @spec query(String.t(), list(), keyword()) :: {:error, term()}
  def query(_sql, _params, _opts), do: {:error, :sqlite_shadow_failed}
end

defmodule Unfinal.RaisingSQLiteShadowRepo do
  @moduledoc false
  @spec query(String.t(), list(), keyword()) :: no_return()
  def query(_sql, _params, _opts), do: raise("sqlite shadow exploded")
end
