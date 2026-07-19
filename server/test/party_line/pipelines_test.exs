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
    test "returns the ordered endpoints + secrets for a ready pipeline", %{pid: pid} do
      {:ok, _} = Pipelines.register(pid, @a, shard("big", 0, 2, url: "http://a.ts.net", secret: "sA"))
      {:ok, _} = Pipelines.register(pid, @b, shard("big", 1, 2, url: "http://b.ts.net", secret: "sB"))

      assert [%{index: 0, url: "http://a.ts.net", secret: "sA"}, %{index: 1, url: "http://b.ts.net", secret: "sB"}] =
               Pipelines.lease(pid, "big")
    end

    test "nil when the pipeline is incomplete", %{pid: pid} do
      {:ok, _} = Pipelines.register(pid, @a, shard("big", 0, 2))
      assert Pipelines.lease(pid, "big") == nil
    end

    test "prefers the fewest-hop split when several are complete", %{pid: pid} do
      # a complete 3-way and a complete 2-way of the same model
      for i <- 0..2, do: {:ok, _} = Pipelines.register(pid, @a, shard("m", i, 3))
      for i <- 0..1, do: {:ok, _} = Pipelines.register(pid, @a, shard("m", i, 2))

      lease = Pipelines.lease(pid, "m")
      assert length(lease) == 2
    end

    test "is case-insensitive on the model id", %{pid: pid} do
      {:ok, _} = Pipelines.register(pid, @a, shard("Big-Model", 0, 2))
      {:ok, _} = Pipelines.register(pid, @b, shard("Big-Model", 1, 2))
      assert [_, _] = Pipelines.lease(pid, "big-model")
    end

    test "a restarted shard's NEW registration wins its slot", %{pid: pid} do
      # the daemon restarts: its dead predecessor is still inside the TTL, but
      # the fresh registration must be the one leased — the old secret is stale
      {:ok, _} = Pipelines.register(pid, @a, shard("m", 0, 2, url: "http://old.ts.net", secret: "sk-old"))
      {:ok, _} = Pipelines.register(pid, @a, shard("m", 0, 2, url: "http://new.ts.net", secret: "sk-new"))
      {:ok, _} = Pipelines.register(pid, @b, shard("m", 1, 2))

      assert [%{index: 0, url: "http://new.ts.net", secret: "sk-new"} | _] =
               Pipelines.lease(pid, "m")
    end

    test "mixed casings across owners still assemble one pipeline", %{pid: pid} do
      {:ok, _} = Pipelines.register(pid, @a, shard("Model-X", 0, 2))
      {:ok, _} = Pipelines.register(pid, @b, shard("model-x", 1, 2))

      # one ready pipeline, not two phantom incomplete ones — and it leases
      assert [%{count: 2, stages_present: 2, ready: true}] = Pipelines.pipelines(pid)
      assert [_, _] = Pipelines.lease(pid, "MODEL-X")
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
  end
end
