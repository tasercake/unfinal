defmodule Synopticon.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SynopticonWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:synopticon, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Synopticon.PubSub},
      Synopticon.ContentStore,
      # Start to serve requests, typically the last entry
      SynopticonWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Synopticon.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SynopticonWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
