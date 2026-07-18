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

  @doc "Test/dev only: drop every cataloged host."
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @doc "Live catalog entries (last heartbeat within TTL), public projection only."
  def list(server \\ __MODULE__),
    do: GenServer.call(server, :list)

  @doc """
  Resolve a live, proxyable host by its model id or name (case-insensitive) to
  the private `%{name, model, url, secret}` the exchange needs to reach it.
  `nil` if there's no live host by that handle, or it registered no secret.

  This is the ONLY place the private url + secret leave the catalog, and it's
  server-internal — never a controller projection. Callers reach a lent model
  *through* the exchange, never by its url.
  """
  def served(server \\ __MODULE__, handle),
    do: GenServer.call(server, {:served, handle})

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

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | hosts: %{}}}
  end

  def handle_call(:list, _from, state) do
    {:reply, live_entries(state), state}
  end

  def handle_call(:count, _from, state) do
    {:reply, length(live_entries(state)), state}
  end

  def handle_call({:served, handle}, _from, state) do
    down = handle |> to_string() |> String.downcase()
    cutoff = now() - state.ttl

    entry =
      state.hosts
      |> Map.values()
      |> Enum.filter(&(&1.mono >= cutoff and is_binary(&1[:secret])))
      |> Enum.find(fn e ->
        String.downcase(e.model) == down or String.downcase(e.name) == down
      end)

    reply = entry && Map.take(entry, [:name, :model, :url, :secret])
    {:reply, reply, state}
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

  # The public projection: what a caller may see. Never the url or secret —
  # a lent model is reached through the exchange, so its address stays private.
  # `served` says it registered a secret and can be proxied.
  defp public(e),
    do: %{
      name: e.name,
      model: e.model,
      last_seen_at: e.last_seen_at,
      served: is_binary(e[:secret])
    }

  defp validate(attrs) do
    with {:ok, name} <- validate_name(fetch(attrs, :name)),
         {:ok, url} <- validate_url(fetch(attrs, :url)),
         {:ok, model} <- validate_model(fetch(attrs, :model)) do
      {:ok, %{name: name, url: url, model: model, secret: validate_secret(fetch(attrs, :secret))}}
    end
  end

  # The secret the exchange presents to the host to prove it's the allowed
  # caller. Optional at the catalog layer (a host may list without lending),
  # but only a host that registers one is proxyable.
  defp validate_secret(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_secret(_), do: nil

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

  defp gen_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp now, do: System.monotonic_time(:millisecond)

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end
