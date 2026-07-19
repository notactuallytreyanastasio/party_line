defmodule PartyLine.Pipelines do
  @moduledoc """
  Catalog of pipeline *shards* — machines each lending a contiguous slice of one
  model's layers, so a model too big for any one host can be assembled from
  several.

  A shard registers `{model, index, count}` (stage `index` of a `count`-way
  split) with its `url` + `secret`. When every stage `0..count-1` of a
  `{model, count}` is live, the exchange can hand out a **lease**: the ordered
  endpoints a harness driver walks a token through, each guarded by a
  short-lived HMAC token derived from that shard's secret — the secret itself
  never leaves the exchange. The server never runs the model — it only catalogs
  shards, assembles pipelines, and leases the endpoints; the driver lives in
  the harness (see `pipeline/driver.py`).

  Like `Hosts`, this is an owner-bound, soft-state registry: an entry is owned
  by the atproto `did` that authenticated it, only that owner may
  heartbeat/deregister it, and a live `{model, count, index}` slot can't be
  claimed by a different owner (so a stranger can't inject a poisoned shard into
  someone else's pipeline). Entries fall out of the catalog once their heartbeat
  ages past the TTL.

  The GenServer is the single writer. `list/0` and `pipelines/0` are the public
  projections (never url or secret); `lease/1`/`lease/2` is the one place a
  shard's *address* leaves the catalog — its secret never does, only tokens
  derived from it.
  """

  use GenServer

  alias PartyLine.PublicUrl

  @default_ttl 90_000
  @default_sweep 30_000
  # how long a lease's HMAC tokens stay valid — generous enough for a long
  # generation and reasonable clock skew; a driver re-leases after expiry
  @default_lease_ttl 3600

  @model_max 128
  @name_max 64
  @count_max 64

  # ── Client API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register (or re-register) a shard owned by `did`. `attrs` needs `model`,
  `index`, `count`, `url`, and `secret` (keys atoms or strings); `name` is
  optional. Returns `{:ok, %{id, ttl_seconds}}` or `{:error, reason}`:

    * `:reserved_name` — the model is one the exchange routes itself
    * `:invalid_stage` — index/count out of range (need `count` 2..#{@count_max},
      `index` in `0..count-1`)
    * `:slot_taken` — a live `{model, count, index}` is owned by someone else
    * a validation reason (`:invalid_url`, `:invalid_model`, `:missing_secret`, …)
  """
  def register(server \\ __MODULE__, did, attrs),
    do: GenServer.call(server, {:register, did, attrs})

  @doc "Refresh a shard's liveness. Owner-only. `{:error, :unknown | :forbidden}`."
  def heartbeat(server \\ __MODULE__, id, did),
    do: GenServer.call(server, {:heartbeat, id, did})

  @doc "Drop a shard you own. Always `:ok` (a no-op if not yours)."
  def deregister(server \\ __MODULE__, id, did),
    do: GenServer.call(server, {:deregister, id, did})

  @doc "Test/dev only: drop every cataloged shard."
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @doc "Live shards, public projection only (model/index/count — never url/secret)."
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc """
  Assembled pipelines, public projection. One row per live `{model, count}`:
  `%{model, count, stages_present, ready}` where `ready` means every stage
  `0..count-1` is live and the model can be leased.
  """
  def pipelines(server \\ __MODULE__), do: GenServer.call(server, :pipelines)

  @doc """
  Lease a ready pipeline for `model`: `%{expires_at, stages: [%{index, url,
  token}]}` — the ordered endpoints a driver walks. Prefers the fewest-hop
  split (smallest `count`). `nil` if no complete pipeline for that model is
  live.

  Each stage's `token` is a short-lived HMAC derived from that shard's secret
  (see `lease_token/5`); the secret itself NEVER leaves the exchange — same
  contract as a lent host. The shard recomputes the MAC from its own
  registration to verify, so a lease expires on its own and a revoked caller
  can't come back for another.
  """
  def lease(server \\ __MODULE__, model), do: GenServer.call(server, {:lease, model})

  @doc """
  The lease token a driver presents to one shard:
  `"plsl1.<expires_at>.<base64url hmac>"`, where the MAC is HMAC-SHA256 over
  `"pl-shard-lease|v1|<model>|<count>|<index>|<expires_at>"` keyed by the
  shard's registered secret. Pure — the shard-side verifier in
  `harness/pipeline/serve_shard.py` mirrors it byte for byte (a shared golden
  vector in both test suites keeps them honest).
  """
  def lease_token(secret, model, count, index, expires_at) do
    payload = "pl-shard-lease|v1|#{model}|#{count}|#{index}|#{expires_at}"
    mac = :hmac |> :crypto.mac(:sha256, secret, payload) |> Base.url_encode64(padding: false)
    "plsl1.#{expires_at}.#{mac}"
  end

  @doc "Number of live shards."
  def count(server \\ __MODULE__), do: GenServer.call(server, :count)

  # ── Server ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    sweep = Keyword.get(opts, :sweep, @default_sweep)
    lease_ttl = Keyword.get(opts, :lease_ttl, @default_lease_ttl)
    schedule_sweep(sweep)
    # `seq` is a strictly-increasing registration counter: `mono` can tie within
    # a millisecond, so "which registration is newest" needs its own order.
    {:ok, %{shards: %{}, ttl: ttl, sweep: sweep, lease_ttl: lease_ttl, seq: 0}}
  end

  @impl true
  def handle_call({:register, did, attrs}, _from, state) do
    with {:ok, fields} <- validate(attrs),
         :ok <- not_reserved(fields),
         :ok <- not_claimed(state, fields, did) do
      id = gen_id()
      seq = state.seq + 1

      entry =
        Map.merge(fields, %{
          id: id,
          did: did,
          seq: seq,
          mono: now(),
          last_seen_at: DateTime.utc_now()
        })

      {:reply, {:ok, %{id: id, ttl_seconds: div(state.ttl, 1000)}},
       %{put_in(state.shards[id], entry) | seq: seq}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:heartbeat, id, did}, _from, state) do
    case Map.get(state.shards, id) do
      nil ->
        {:reply, {:error, :unknown}, state}

      %{did: owner} when owner != did ->
        {:reply, {:error, :forbidden}, state}

      entry ->
        entry = %{entry | mono: now(), last_seen_at: DateTime.utc_now()}
        {:reply, :ok, put_in(state.shards[id], entry)}
    end
  end

  def handle_call({:deregister, id, did}, _from, state) do
    case Map.get(state.shards, id) do
      %{did: owner} when owner == did ->
        {:reply, :ok, update_in(state.shards, &Map.delete(&1, id))}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | shards: %{}}}
  end

  def handle_call(:list, _from, state) do
    {:reply, Enum.map(live(state), &public/1), state}
  end

  def handle_call(:count, _from, state) do
    {:reply, length(live(state)), state}
  end

  def handle_call(:pipelines, _from, state) do
    {:reply, assemble(live(state)), state}
  end

  def handle_call({:lease, model}, _from, state) do
    {:reply, lease_for(live(state), to_string(model), state.lease_ttl), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now() - state.ttl
    shards = for {id, e} <- state.shards, e.mono >= cutoff, into: %{}, do: {id, e}
    schedule_sweep(state.sweep)
    {:noreply, %{state | shards: shards}}
  end

  # ── Assembly ───────────────────────────────────────────────────────────────

  # Group live shards by {model, count}; a group is ready when every stage index
  # 0..count-1 is present. The model key is case-insensitive to match `lease` —
  # two casings of one model are one pipeline, not two phantom incomplete ones.
  defp assemble(entries) do
    entries
    |> Enum.group_by(&{String.downcase(&1.model), &1.count})
    |> Enum.map(fn {{_down, count}, shards} ->
      present = shards |> Enum.map(& &1.index) |> MapSet.new()

      %{
        model: hd(shards).model,
        count: count,
        stages_present: MapSet.size(present),
        ready: complete?(present, count)
      }
    end)
    |> Enum.sort_by(&{&1.model, &1.count})
  end

  defp lease_for(entries, model, lease_ttl) do
    entries
    |> Enum.filter(&(String.downcase(&1.model) == String.downcase(model)))
    |> Enum.group_by(& &1.count)
    # fewest hops first: a complete 2-way beats a complete 4-way
    |> Enum.sort_by(fn {count, _} -> count end)
    |> Enum.find_value(fn {count, shards} -> assemble_lease(shards, count, lease_ttl) end)
  end

  # One shard per stage (the NEWEST registration wins a tie), ordered
  # 0..count-1, only if every stage is present. Newest matters: a restarted
  # daemon re-registers with a fresh secret while its dead predecessor is still
  # inside the TTL — leasing the old entry would derive tokens from a stale
  # secret for up to 90s.
  defp assemble_lease(shards, count, lease_ttl) do
    by_index =
      shards
      |> Enum.sort_by(& &1.seq)
      |> Enum.reduce(%{}, fn e, acc -> Map.put(acc, e.index, e) end)

    if complete?(MapSet.new(Map.keys(by_index)), count) do
      expires_at = System.os_time(:second) + lease_ttl

      stages =
        for i <- 0..(count - 1) do
          e = by_index[i]
          %{index: i, url: e.url, token: lease_token(e.secret, e.model, e.count, e.index, expires_at)}
        end

      %{expires_at: expires_at, stages: stages}
    end
  end

  defp complete?(present, count), do: MapSet.equal?(present, MapSet.new(0..(count - 1)))

  # ── Internals ────────────────────────────────────────────────────────────

  defp live(state) do
    cutoff = now() - state.ttl

    state.shards
    |> Map.values()
    |> Enum.filter(&(&1.mono >= cutoff))
    |> Enum.sort_by(&{&1.model, &1.count, &1.index})
  end

  # The public projection: a caller sees which slices exist, never how to reach
  # them. A pipeline is reached by leasing it, not by a shard's address.
  defp public(e),
    do: %{model: e.model, index: e.index, count: e.count, name: e.name, last_seen_at: e.last_seen_at}

  defp validate(attrs) do
    with {:ok, model} <- validate_model(fetch(attrs, :model)),
         {:ok, index, count} <- validate_stage(fetch(attrs, :index), fetch(attrs, :count)),
         {:ok, url} <- PublicUrl.validate(fetch(attrs, :url)),
         {:ok, secret} <- validate_secret(fetch(attrs, :secret)) do
      {:ok, %{model: model, index: index, count: count, url: url, secret: secret, name: name(attrs)}}
    end
  end

  defp not_reserved(%{model: model}) do
    if PartyLine.ReservedModels.reserved?(model), do: {:error, :reserved_name}, else: :ok
  end

  # A live {model, count, index} slot belongs to whoever registered it first — a
  # different identity can't claim it, so it can't slip a poisoned shard into a
  # pipeline. The same owner re-registering is fine (the old entry TTLs out).
  defp not_claimed(state, %{model: model, count: count, index: index}, did) do
    cutoff = now() - state.ttl
    down = String.downcase(model)

    taken? =
      Enum.any?(state.shards, fn {_id, e} ->
        e.mono >= cutoff and e.did != did and e.count == count and e.index == index and
          String.downcase(e.model) == down
      end)

    if taken?, do: {:error, :slot_taken}, else: :ok
  end

  defp validate_model(model) when is_binary(model) do
    trimmed = String.trim(model)
    if String.length(trimmed) in 1..@model_max, do: {:ok, trimmed}, else: {:error, :invalid_model}
  end

  defp validate_model(_), do: {:error, :invalid_model}

  defp validate_stage(index, count) do
    with {:ok, count} <- to_int(count),
         {:ok, index} <- to_int(index),
         true <- count in 2..@count_max and index in 0..(count - 1) do
      {:ok, index, count}
    else
      _ -> {:error, :invalid_stage}
    end
  end

  # A shard is only useful if the driver can reach it, so a secret is required
  # (unlike a bare lent host, which may list without lending).
  defp validate_secret(s) when is_binary(s) do
    case String.trim(s) do
      "" -> {:error, :missing_secret}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_secret(_), do: {:error, :missing_secret}

  defp name(attrs) do
    case fetch(attrs, :name) do
      n when is_binary(n) -> n |> String.trim() |> String.slice(0, @name_max)
      _ -> nil
    end
  end

  defp to_int(v) when is_integer(v), do: {:ok, v}

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp to_int(_), do: :error

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
