defmodule UnfinalWeb.Auth.ClerkOAuth do
  @moduledoc false

  @callback authorize_url(Keyword.t()) ::
              {:ok, %{url: binary(), session_params: map()}} | {:error, term()}
  @callback callback(Keyword.t(), map()) :: {:ok, %{user: map()}} | {:error, term()}

  @behaviour __MODULE__

  @impl true
  def authorize_url(config), do: Assent.Strategy.OIDC.authorize_url(config)

  @impl true
  def callback(config, params), do: Assent.Strategy.OIDC.callback(config, params)
end
