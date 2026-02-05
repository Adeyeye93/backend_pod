defmodule Pod.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PodWeb.Telemetry,
      Pod.Repo,
      {DNSCluster, query: Application.get_env(:pod, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Pod.PubSub},
      {Pod.RTMPServer, [port: 1935]},  
      # Start a worker by calling: Pod.Worker.start_link(arg)
      # {Pod.Worker, arg},
      # Start to serve requests, typically the last entry
      PodWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pod.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PodWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
