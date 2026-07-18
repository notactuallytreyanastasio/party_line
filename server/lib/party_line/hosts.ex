defmodule PartyLine.Hosts do
  @moduledoc """
  Catalog of tailnet-exposed LLM hosts.

  A neighbor runs a daemon that lends a bare model (not a persona) over their
  tailnet; while that daemon is alive it heartbeats us, and we list it. This is
  a soft-state registry: an entry lives only as long as its last heartbeat is
  within the TTL, and falls out of the catalog on the next sweep — no explicit
  teardown required (though `deregister/3` is the polite exit).

  Registration is **identity-bound**: an entry is owned by the atproto `did`
  that authenticated it, only that owner may heartbeat/deregister it, and no
  one may claim a reserved handle (the router aliases / model families) or a
  name/model already held by a different owner. The registered `url` must be a
  public address — loopback, link-local, and private ranges are rejected so the
  exchange can't be turned into an SSRF proxy.

  The GenServer is the single writer of the catalog map. `list/0` is the public
  projection (names/models only — never url or secret); `served/2` is the one
  server-internal place the address + secret leave the catalog, for the proxy.
  """

  use GenServer

  @default_ttl 90_000
  @default_sweep 30_000

  @name_max 64
  @model_max 128

  # Handles the exchange routes on its own (the router aliases + the model
  # families in Agents.Target). A lent host may never claim one, or it could
  # shadow the default route / a family and intercept prompts.
  @reserved ~w(party-line-auto auto default party-line gpt-oss gemma llama qwen mistral phi)

  # ── Client API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register (or re-register) a host, owned by `did` (the atproto identity that
  authenticated the call). `attrs` needs `name`, `url`, `model`, and `secret`;
  keys may be atoms or strings. Returns `{:ok, %{id, ttl_seconds}}` with a fresh
  16-hex id, or `{:error, reason}`:

    * `:reserved_name` — the name/model is one the exchange routes itself
    * `:name_taken` — a live entry with that name/model is owned by someone else
    * a validation reason (`:invalid_url`, …)
  """
  def register(server \\ __MODULE__, did, attrs),
    do: GenServer.call(server, {:register, did, attrs})

  @doc "Refresh a host's liveness. Owner-only. `{:error, :unknown | :forbidden}`."
  def heartbeat(server \\ __MODULE__, id, did),
    do: GenServer.call(server, {:heartbeat, id, did})

  @doc "Drop a host you own from the catalog. Always `:ok` (a no-op if not yours)."
  def deregister(server \\ __MODULE__, id, did),
    do: GenServer.call(server, {:deregister, id, did})

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
  def handle_call({:register, did, attrs}, _from, state) do
    with {:ok, fields} <- validate(attrs),
         :ok <- not_reserved(fields),
         :ok <- not_claimed(state, fields, did) do
      id = gen_id()

      entry =
        Map.merge(fields, %{id: id, did: did, mono: now(), last_seen_at: DateTime.utc_now()})

      {:reply, {:ok, %{id: id, ttl_seconds: div(state.ttl, 1000)}},
       put_in(state.hosts[id], entry)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:heartbeat, id, did}, _from, state) do
    case Map.get(state.hosts, id) do
      nil ->
        {:reply, {:error, :unknown}, state}

      %{did: owner} when owner != did ->
        {:reply, {:error, :forbidden}, state}

      entry ->
        entry = %{entry | mono: now(), last_seen_at: DateTime.utc_now()}
        {:reply, :ok, put_in(state.hosts[id], entry)}
    end
  end

  def handle_call({:deregister, id, did}, _from, state) do
    case Map.get(state.hosts, id) do
      %{did: owner} when owner == did ->
        {:reply, :ok, update_in(state.hosts, &Map.delete(&1, id))}

      _ ->
        # not yours, or already gone — a no-op, but always :ok
        {:reply, :ok, state}
    end
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

    # match on the model id ONLY (not the display name): a caller targets a lent
    # model by its model id, and matching names too would let a host named after
    # a persona shadow that persona.
    entry =
      state.hosts
      |> Map.values()
      |> Enum.filter(&(&1.mono >= cutoff and is_binary(&1[:secret])))
      |> Enum.find(&(String.downcase(&1.model) == down))

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

  defp not_reserved(%{name: name, model: model}) do
    if String.downcase(name) in @reserved or String.downcase(model) in @reserved,
      do: {:error, :reserved_name},
      else: :ok
  end

  # A live name/model belongs to whoever registered it first — a different
  # identity can't claim it out from under them. The same owner re-registering
  # is fine (the old entry TTLs out).
  defp not_claimed(state, %{name: name, model: model}, did) do
    cutoff = now() - state.ttl
    down_name = String.downcase(name)
    down_model = String.downcase(model)

    taken? =
      Enum.any?(state.hosts, fn {_id, e} ->
        e.mono >= cutoff and e.did != did and
          (String.downcase(e.name) == down_name or String.downcase(e.model) == down_model)
      end)

    if taken?, do: {:error, :name_taken}, else: :ok
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

  defp validate_url("http://" <> rest = url) when rest != "", do: public_url(url)
  defp validate_url("https://" <> rest = url) when rest != "", do: public_url(url)
  defp validate_url(_), do: {:error, :invalid_url}

  # The exchange makes an outbound request to this url, so it must not point at
  # our own network: reject loopback, link-local (incl. cloud metadata at
  # 169.254.169.254), and private ranges, plus obvious internal names. This
  # blocks SSRF via IP literals; a public name that resolves private is a
  # residual we mitigate with `redirect: false` at proxy time.
  defp public_url(url) do
    host = url |> URI.parse() |> Map.get(:host) |> to_string() |> String.downcase()

    cond do
      host == "" -> {:error, :invalid_url}
      host in ~w(localhost metadata.google.internal metadata) -> {:error, :private_url}
      String.ends_with?(host, [".local", ".internal"]) -> {:error, :private_url}
      private_ip?(host) -> {:error, :private_url}
      true -> {:ok, url}
    end
  end

  defp private_ip?(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, addr} -> blocked_ip?(addr)
      _ -> false
    end
  end

  defp blocked_ip?({127, _, _, _}), do: true
  defp blocked_ip?({10, _, _, _}), do: true
  defp blocked_ip?({192, 168, _, _}), do: true
  defp blocked_ip?({169, 254, _, _}), do: true
  defp blocked_ip?({172, b, _, _}) when b in 16..31, do: true
  defp blocked_ip?({0, 0, 0, 0}), do: true
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp blocked_ip?(_), do: false

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
