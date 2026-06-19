defmodule UnfinalWeb.FakeClerkOAuth do
  @moduledoc false
  @behaviour UnfinalWeb.Auth.ClerkOAuth

  @impl true
  def authorize_url(config) do
    send(self(), {:authorize_url, config})

    {:ok,
     %{
       url: "https://clerk.example/oauth/authorize?state=fake",
       session_params: %{state: "fake", nonce: "fake"}
     }}
  end

  @impl true
  def callback(config, params) do
    send(self(), {:callback, config, params})

    case params do
      %{"code" => "ok"} ->
        {:ok,
         %{user: %{"sub" => "user_123", "email" => "USER@example.COM", "email_verified" => true}}}

      %{"code" => "unverified"} ->
        {:ok,
         %{user: %{"sub" => "user_123", "email" => "user@example.com", "email_verified" => false}}}

      %{"code" => "missing_email"} ->
        {:ok, %{user: %{"sub" => "user_123", "email_verified" => true}}}

      _params ->
        {:error, :invalid_callback}
    end
  end
end
