defmodule PartyLine.Hosts do
  @moduledoc """
  Catalog of tailnet-exposed LLM hosts.

  A neighbor runs a daemon that lends a bare model (not a persona) over
  their tailnet; while that daemon is alive it heartbeats us, and we list
  it. This is a soft-state registry: an entry lives only as long as its
  last heartbeat is within the TTL. A daemon that dies stops heartbeating
  and falls out of the catalog on the next sweep — no explicit teardown
  required (though `deregister/1` is the polite exit).

  The GenServer is the single writer of the catalog map. `list/0` filters
  to live entries at read time, so a stale-but-not-yet-swept entry never
  leaks out even between sweeps.
  """

  use GenServer

  @default_ttl 90_000
  @default_sweep 30_000

  @name_max 64
  @model_max 128

  # ── Client API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register (or re-register) a host. `attrs` needs `name`, `url`, `model`
  and `requires_token`; keys may be atoms or strings. Returns
  `{:ok, %{id: id, ttl_seconds: n}}` with a fresh 16-hex id, or
  `{:error, reason}` when validation fails.
  """
  def register(server \\ __MODULE__, attrs),
    do: GenServer.call(server, {:register, attrs})

  @doc "Refresh a host's liveness. `{:error, :unknown}` if it isn't cataloged."
  def heartbeat(server \\ __MODULE__, id),
    do: GenServer.call(server, {:heartbeat, id})

  @doc "Politely drop a host from the catalog. Always `:ok`."
  def deregister(server \\ __MODULE__, id),
    do: GenServer.call(server, {:deregister, id})

  @doc "Live catalog entries (last heartbeat within TTL)."
  def list(server \\ __MODULE__),
    do: GenServer.call(server, :list)

  @doc "Number of live catalog entries."
  def count(server \\ __MODULE__),
    do: GenServer.call(server, :count)

  # ── Server ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    sweep = Keyword.get(opts, :sweep, @default_sweep)
    schedule_sweep(sweep)
    {:ok, %{hosts: %{}, ttl: ttl, sweep: sweep}}
  end

  @impl true
  def handle_call({:register, attrs}, _from, state) do
    case validate(attrs) do
      {:ok, fields} ->
        id = gen_id()

        entry =
          fields
          |> Map.put(:id, id)
          |> Map.put(:mono, now())
          |> Map.put(:last_seen_at, DateTime.utc_now())

        state = put_in(state.hosts[id], entry)
        {:reply, {:ok, %{id: id, ttl_seconds: div(state.ttl, 1000)}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:heartbeat, id}, _from, state) do
    case Map.get(state.hosts, id) do
      nil ->
        {:reply, {:error, :unknown}, state}

      entry ->
        entry = %{entry | mono: now(), last_seen_at: DateTime.utc_now()}
        {:reply, :ok, put_in(state.hosts[id], entry)}
    end
  end

  def handle_call({:deregister, id}, _from, state) do
    {:reply, :ok, update_in(state.hosts, &Map.delete(&1, id))}
  end

  def handle_call(:list, _from, state) do
    {:reply, live_entries(state), state}
  end

  def handle_call(:count, _from, state) do
    {:reply, length(live_entries(state)), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now() - state.ttl
    hosts = for {id, e} <- state.hosts, e.mono >= cutoff, into: %{}, do: {id, e}
    schedule_sweep(state.sweep)
    {:noreply, %{state | hosts: hosts}}
  end

  # ── Internals ────────────────────────────────────────────────────────────

  defp live_entries(state) do
    cutoff = now() - state.ttl

    state.hosts
    |> Map.values()
    |> Enum.filter(&(&1.mono >= cutoff))
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&public/1)
  end

  defp public(e),
    do: Map.take(e, [:id, :name, :url, :model, :requires_token, :last_seen_at])

  defp validate(attrs) do
    with {:ok, name} <- validate_name(fetch(attrs, :name)),
         {:ok, url} <- validate_url(fetch(attrs, :url)),
         {:ok, model} <- validate_model(fetch(attrs, :model)) do
      requires_token = truthy(fetch(attrs, :requires_token))

      {:ok, %{name: name, url: url, model: model, requires_token: requires_token}}
    end
  end

  defp validate_name(name) when is_binary(name) do
    trimmed = String.trim(name)
    len = String.length(trimmed)
    if len in 1..@name_max, do: {:ok, trimmed}, else: {:error, :invalid_name}
  end

  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_url("http://" <> rest = url) when rest != "", do: {:ok, url}
  defp validate_url("https://" <> rest = url) when rest != "", do: {:ok, url}
  defp validate_url(_), do: {:error, :invalid_url}

  defp validate_model(model) when is_binary(model) do
    trimmed = String.trim(model)
    len = String.length(trimmed)
    if len in 1..@model_max, do: {:ok, trimmed}, else: {:error, :invalid_model}
  end

  defp validate_model(_), do: {:error, :invalid_model}

  # Accept atom- or string-keyed maps (public API vs JSON params).
  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, v} -> v
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false

  defp gen_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp now, do: System.monotonic_time(:millisecond)

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end
