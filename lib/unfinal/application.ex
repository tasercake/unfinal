defmodule Unfinal.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Unfinal.Env.load_and_configure!()

    # Phase 5 (SQLite primary): do NOT start PageIndexServer or its
    # supervisor/index registry. PageIndex is now a SQLite facade.
    # PageIndexServer module is kept for Phase 7 deletion.
    page_index_children =
      if Application.get_env(:unfinal, :storage_mode) == :sqlite_primary_r2_dual_write do
        []
      else
        [
          {Registry, keys: :unique, name: Unfinal.PageIndexRegistry},
          {DynamicSupervisor, strategy: :one_for_one, name: Unfinal.PageIndexSupervisor},
          {Task.Supervisor, name: Unfinal.PageIndexTaskSupervisor}
        ]
      end

    children =
      [
        UnfinalWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:unfinal, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Unfinal.PubSub},
        Unfinal.Repo,
        {Registry, keys: :unique, name: Unfinal.DocumentRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: Unfinal.DocumentSupervisor},
        {Task.Supervisor, name: Unfinal.DocumentTaskSupervisor}
      ] ++
        page_index_children ++
        [
          Unfinal.NamespaceStore,
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
