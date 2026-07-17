defmodule PartyLine.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PartyLineWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:party_line, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: PartyLine.PubSub},
        # Root chat tree ingestion. Always started; no-ops when :memory is
        # disabled, and degrades gracefully when the deciduous daemon is down.
        PartyLine.Memory.Ingest,
        {PartyLine.Buddies, []},
        {PartyLine.DMs, []},
        {PartyLine.Clips, []},
        {PartyLine.ATProto.Sessions, []},
        {PartyLine.Seeds, []},
        {PartyLine.Boards, []},
        {PartyLine.Bots, []},
        {PartyLine.Asks, []},
        {PartyLine.Boards.Scheduler, []},
        # Soft-state catalog of tailnet-exposed LLM hosts.
        PartyLine.Hosts
      ] ++
        PartyLine.Rooms.child_specs() ++
        [
          # Start to serve requests, typically the last entry
          PartyLineWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PartyLine.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PartyLineWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
