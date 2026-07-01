defmodule Unfinal.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Unfinal.Env.load_and_configure!()

    children =
      [
        UnfinalWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:unfinal, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Unfinal.PubSub},
        Unfinal.Repo,
        {Registry, keys: :unique, name: Unfinal.DocumentRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: Unfinal.DocumentSupervisor},
        {Task.Supervisor, name: Unfinal.DocumentTaskSupervisor},
        # Start to serve requests, typically the last entry
        UnfinalWeb.Endpoint
      ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Unfinal.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UnfinalWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
