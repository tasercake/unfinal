defmodule UnfinalWeb.FakeClerkOAuth do
  @moduledoc false
  @behaviour UnfinalWeb.Auth.ClerkOAuth

  @impl true
  def authorize_url(config) do
    send(self(), {:authorize_url, config})

    state = next_state()

    {:ok,
     %{
       url: "https://clerk.example/oauth/authorize?state=#{state}",
       session_params: %{state: state, nonce: "fake"}
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

      %{"code" => "csrf_error"} ->
        {:error, %Assent.CallbackCSRFError{key: "state"}}

      _params ->
        {:error, :invalid_callback}
    end
  end

  defp next_state do
    counter = Process.get(:fake_clerk_oauth_counter, 0) + 1
    Process.put(:fake_clerk_oauth_counter, counter)
    "fake-#{counter}"
  end
end
