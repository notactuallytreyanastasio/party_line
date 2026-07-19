defmodule PartyLine.PipelinesTest do
  use ExUnit.Case, async: true

  alias PartyLine.Pipelines

  @a "did:plc:alice"
  @b "did:plc:bob"

  setup do
    # short TTL/sweep so liveness/expiry are testable at millisecond scale
    {:ok, pid} = Pipelines.start_link(name: nil, ttl: 60_000, sweep: 60_000)
    %{pid: pid}
  end

  defp shard(model, index, count, opts \\ []) do
    %{
      model: model,
      index: index,
      count: count,
      url: Keyword.get(opts, :url, "http://shard-#{index}.ts.net:8378"),
      secret: Keyword.get(opts, :secret, "sk-#{index}")
    }
  end

  describe "register" do
    test "registers a shard and returns an id + ttl", %{pid: pid} do
      assert {:ok, %{id: id, ttl_seconds: ttl}} = Pipelines.register(pid, @a, shard("m", 0, 2))
      assert id =~ ~r/\A[0-9a-f]{16}\z/
      assert ttl == 60
    end

    test "rejects an out-of-range stage", %{pid: pid} do
      assert {:error, :invalid_stage} = Pipelines.register(pid, @a, shard("m", 2, 2))
      assert {:error, :invalid_stage} = Pipelines.register(pid, @a, shard("m", 0, 1))
    end

    test "requires a secret (a driver must be able to reach it)", %{pid: pid} do
      attrs = shard("m", 0, 2) |> Map.put(:secret, "")
      assert {:error, :missing_secret} = Pipelines.register(pid, @a, attrs)
    end

    test "rejects a private/loopback url (SSRF guard)", %{pid: pid} do
      attrs = shard("m", 0, 2) |> Map.put(:url, "http://127.0.0.1:8378")
      assert {:error, :private_url} = Pipelines.register(pid, @a, attrs)
    end

    test "rejects a reserved model id", %{pid: pid} do
      assert {:error, :reserved_name} = Pipelines.register(pid, @a, shard("party-line-auto", 0, 2))
    end

    test "a different owner can't claim a live slot", %{pid: pid} do
      assert {:ok, _} = Pipelines.register(pid, @a, shard("m", 1, 2))
      assert {:error, :slot_taken} = Pipelines.register(pid, @b, shard("m", 1, 2))
      # a different stage of the same model is fine (cross-owner pooling)
      assert {:ok, _} = Pipelines.register(pid, @b, shard("m", 0, 2))
    end

    test "string-keyed params (JSON) and string ints are accepted", %{pid: pid} do
      params = %{"model" => "m", "index" => "1", "count" => "2", "url" => "http://x.ts.net", "secret" => "s"}
      assert {:ok, _} = Pipelines.register(pid, @a, params)
    end
  end

  describe "list — public projection" do
    test "never leaks url or secret", %{pid: pid} do
      {:ok, _} = Pipelines.register(pid, @a, shard("m", 0, 2))
      assert [entry] = Pipelines.list(pid)
      assert entry.model == "m" and entry.index == 0 and entry.count == 2
      refute Map.has_key?(entry, :url)
      refute Map.has_key?(entry, :secret)
    end
  end

  describe "pipelines — assembly" do
    test "a model is ready only when every stage is present", %{pid: pid} do
      {:ok, _} = Pipelines.register(pid, @a, shard("big", 0, 2))
      assert [%{model: "big", count: 2, stages_present: 1, ready: false}] = Pipelines.pipelines(pid)

      {:ok, _} = Pipelines.register(pid, @b, shard("big", 1, 2))
      assert [%{model: "big", count: 2, stages_present: 2, ready: true}] = Pipelines.pipelines(pid)
    end

    test "separate {model,count} groups are assembled independently", %{pid: pid} do
      {:ok, _} = Pipelines.register(pid, @a, shard("m", 0, 2))
      {:ok, _} = Pipelines.register(pid, @a, shard("m", 1, 2))
      {:ok, _} = Pipelines.register(pid, @a, shard("n", 0, 3))

      rows = Pipelines.pipelines(pid)
      assert %{model: "m", count: 2, ready: true} = Enum.find(rows, &(&1.model == "m"))
      assert %{model: "n", count: 3, ready: false} = Enum.find(rows, &(&1.model == "n"))
    end
  end

  describe "lease" do
    test "returns ordered endpoints with HMAC tokens — never a secret", %{pid: pid} do
      {:ok, _} = Pipelines.register(pid, @a, shard("big", 0, 2, url: "http://a.ts.net", secret: "sA"))
      {:ok, _} = Pipelines.register(pid, @b, shard("big", 1, 2, url: "http://b.ts.net", secret: "sB"))

      assert %{expires_at: expires_at, stages: [s0, s1]} = Pipelines.lease(pid, "big")
      assert %{index: 0, url: "http://a.ts.net", token: t0} = s0
      assert %{index: 1, url: "http://b.ts.net", token: t1} = s1
      refute Map.has_key?(s0, :secret)

      # each token is exactly the HMAC a shard can recompute from its own
      # registration — derived from ITS secret, scoped to ITS slot
      assert t0 == Pipelines.lease_token("sA", "big", 2, 0, expires_at)
      assert t1 == Pipelines.lease_token("sB", "big", 2, 1, expires_at)
      assert expires_at > System.os_time(:second)
    end

    test "lease_token/5 matches the cross-language golden vector" do
      # the same literal is asserted by the Python shard verifier's test suite;
      # if either side drifts from the shared payload format, one of them fails
      assert Pipelines.lease_token("topsecret", "m", 2, 0, 4_102_444_800) ==
               "plsl1.4102444800.DzpLeYVJbwyWkV1v-849eDtEuryatPHpbJK6leuvxbo"
    end

    test "nil when the pipeline is incomplete", %{pid: pid} do
      {:ok, _} = Pipelines.register(pid, @a, shard("big", 0, 2))
      assert Pipelines.lease(pid, "big") == nil
    end

    test "prefers the fewest-hop split when several are complete", %{pid: pid} do
      # a complete 3-way and a complete 2-way of the same model
      for i <- 0..2, do: {:ok, _} = Pipelines.register(pid, @a, shard("m", i, 3))
      for i <- 0..1, do: {:ok, _} = Pipelines.register(pid, @a, shard("m", i, 2))

      assert %{stages: stages} = Pipelines.lease(pid, "m")
      assert length(stages) == 2
    end

    test "is case-insensitive on the model id", %{pid: pid} do
      {:ok, _} = Pipelines.register(pid, @a, shard("Big-Model", 0, 2))
      {:ok, _} = Pipelines.register(pid, @b, shard("Big-Model", 1, 2))
      assert %{stages: [_, _]} = Pipelines.lease(pid, "big-model")
    end

    test "a restarted shard's NEW registration wins its slot", %{pid: pid} do
      # the daemon restarts: its dead predecessor is still inside the TTL, but
      # the fresh registration must be the one leased — the old secret is stale
      {:ok, _} = Pipelines.register(pid, @a, shard("m", 0, 2, url: "http://old.ts.net", secret: "sk-old"))
      {:ok, _} = Pipelines.register(pid, @a, shard("m", 0, 2, url: "http://new.ts.net", secret: "sk-new"))
      {:ok, _} = Pipelines.register(pid, @b, shard("m", 1, 2))

      assert %{expires_at: exp, stages: [%{index: 0, url: "http://new.ts.net", token: t0} | _]} =
               Pipelines.lease(pid, "m")

      assert t0 == Pipelines.lease_token("sk-new", "m", 2, 0, exp)
    end

    test "mixed casings across owners still assemble one pipeline", %{pid: pid} do
      {:ok, _} = Pipelines.register(pid, @a, shard("Model-X", 0, 2))
      {:ok, _} = Pipelines.register(pid, @b, shard("model-x", 1, 2))

      # one ready pipeline, not two phantom incomplete ones — and it leases
      assert [%{count: 2, stages_present: 2, ready: true}] = Pipelines.pipelines(pid)
      assert %{stages: [_, _]} = Pipelines.lease(pid, "MODEL-X")
    end
  end

  describe "liveness" do
    test "expired shards drop out of list/pipelines", %{pid: pid} do
      {:ok, %{id: id}} = Pipelines.register(pid, @a, shard("m", 0, 2))
      assert Pipelines.count(pid) == 1

      # a negative TTL makes everything already expired on the next read
      {:ok, dead} = Pipelines.start_link(name: nil, ttl: -1, sweep: 60_000)
      {:ok, _} = Pipelines.register(dead, @a, shard("m", 0, 2))
      assert Pipelines.list(dead) == []
      assert Pipelines.pipelines(dead) == []
      assert Pipelines.lease(dead, "m") == nil

      # owner-only heartbeat still governs the live registry
      assert {:error, :forbidden} = Pipelines.heartbeat(pid, id, @b)
      assert :ok = Pipelines.heartbeat(pid, id, @a)
    end

    test "the sweep timer actually prunes dead shards from state", %{pid: _pid} do
      # a real TTL with a fast sweep — the timer (not just the read filter) must
      # drop the entry, and reschedule itself so it keeps sweeping
      {:ok, sweeper} = Pipelines.start_link(name: nil, ttl: 20, sweep: 20)
      {:ok, _} = Pipelines.register(sweeper, @a, shard("m", 0, 2))
      assert Pipelines.count(sweeper) == 1

      # wait out the TTL + a couple sweep ticks
      Process.sleep(120)
      assert Pipelines.count(sweeper) == 0

      # the timer is still alive and pruning a second registration too
      {:ok, _} = Pipelines.register(sweeper, @a, shard("m", 1, 2))
      Process.sleep(120)
      assert Pipelines.count(sweeper) == 0
    end
  end
end
