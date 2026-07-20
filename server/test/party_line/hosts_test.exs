defmodule PartyLine.HostsTest do
  # Async-safe: each test drives its own unnamed instance with a
  # millisecond-scale TTL + sweep, never the app-started catalog.
  use ExUnit.Case, async: true

  alias PartyLine.Hosts

  @valid %{
    name: "gpu-closet",
    url: "http://gpu-closet.tailnet.ts.net:8080",
    model: "qwen2.5-coder-7b",
    requires_token: true,
    secret: "sk-host-secret"
  }

  @did "did:plc:owner"

  defp start(opts \\ []) do
    start_supervised!(
      {Hosts, Keyword.merge([ttl: 60, sweep: 20, name: nil], opts)},
      id: {Hosts, System.unique_integer()}
    )
  end

  test "register returns a 16-hex id and the ttl in seconds" do
    h = start(ttl: 90_000)
    assert {:ok, %{id: id, ttl_seconds: 90}} = Hosts.register(h, @did, @valid)
    assert id =~ ~r/\A[0-9a-f]{16}\z/
  end

  test "a registered host shows up in the live list and count" do
    h = start()
    {:ok, %{id: id}} = Hosts.register(h, @did, @valid)

    assert Hosts.count(h) == 1
    assert [entry] = Hosts.list(h)
    assert entry.name == "gpu-closet"
    assert entry.model == "qwen2.5-coder-7b"
    assert entry.served == true
    assert %DateTime{} = entry.last_seen_at

    # the public projection never leaks how to reach the host directly
    refute Map.has_key?(entry, :url)
    refute Map.has_key?(entry, :secret)
    refute Map.has_key?(entry, :id)
    _ = id
  end

  test "served/2 resolves a proxyable host by MODEL id (case-insensitive), never by name" do
    h = start()
    {:ok, _} = Hosts.register(h, @did, @valid)

    assert %{url: url, secret: "sk-host-secret", model: "qwen2.5-coder-7b", name: "gpu-closet"} =
             Hosts.served(h, "QWEN2.5-CODER-7B")

    assert url == @valid.url
    # the display name must NOT resolve — that would let a host shadow a persona
    assert Hosts.served(h, "gpu-closet") == nil
    assert Hosts.served(h, "no-such-model") == nil
  end

  describe "registration is identity-bound and gated" do
    test "reserved names/aliases/families can't be claimed by a lent host" do
      h = start()

      for reserved <- ~w(party-line-auto auto gemma llama gpt-oss) do
        assert {:error, :reserved_name} = Hosts.register(h, @did, %{@valid | model: reserved})
        assert {:error, :reserved_name} = Hosts.register(h, @did, %{@valid | name: reserved})
      end
    end

    test "a different owner can't claim a live name or model" do
      h = start()
      {:ok, _} = Hosts.register(h, "did:plc:alice", @valid)

      assert {:error, :name_taken} = Hosts.register(h, "did:plc:mallory", @valid)
      # same name, different model — still taken (name collision)
      assert {:error, :name_taken} =
               Hosts.register(h, "did:plc:mallory", %{@valid | model: "other-model"})

      # the original owner can re-register fine
      assert {:ok, _} = Hosts.register(h, "did:plc:alice", @valid)
    end

    test "heartbeat and deregister are owner-only" do
      h = start()
      {:ok, %{id: id}} = Hosts.register(h, "did:plc:alice", @valid)

      assert {:error, :forbidden} = Hosts.heartbeat(h, id, "did:plc:mallory")
      # mallory's deregister is a silent no-op — the host stays
      assert :ok = Hosts.deregister(h, id, "did:plc:mallory")
      assert Hosts.count(h) == 1

      assert :ok = Hosts.heartbeat(h, id, "did:plc:alice")
      assert :ok = Hosts.deregister(h, id, "did:plc:alice")
      assert Hosts.count(h) == 0
    end

    test "an internal / private / loopback url is rejected (SSRF)" do
      h = start()

      for bad <- [
            "http://127.0.0.1:8377",
            "http://localhost/v1",
            "http://169.254.169.254/latest/meta-data",
            "http://10.0.0.5:8080",
            "http://192.168.1.9",
            "http://172.16.4.4",
            "http://[::1]:9000",
            "http://box.internal",
            "https://printer.local"
          ] do
        assert {:error, :private_url} = Hosts.register(h, @did, %{@valid | url: bad}),
               "expected #{bad} to be rejected"
      end

      # a public tailnet/funnel host is fine
      assert {:ok, _} = Hosts.register(h, @did, %{@valid | url: "https://mochi.tailabc.ts.net"})
    end
  end

  test "a host that registered no secret is listed but not proxyable" do
    h = start()
    {:ok, _} = Hosts.register(h, @did, Map.delete(@valid, :secret))

    assert [%{served: false}] = Hosts.list(h)
    assert Hosts.served(h, "qwen2.5-coder-7b") == nil
  end

  test "heartbeat keeps an entry alive past the TTL" do
    h = start(ttl: 60, sweep: 15)
    {:ok, %{id: id}} = Hosts.register(h, @did, @valid)

    # Beat across more than one TTL's worth of time; the entry survives because
    # each heartbeat refreshes its monotonic clock. This one genuinely needs a
    # real (small) sleep — liveness is monotonic-time-based with no clock to
    # inject — so keep it minimal: 3×25ms = 75ms clears ttl 60 with margin.
    for _ <- 1..3 do
      Process.sleep(25)
      assert :ok = Hosts.heartbeat(h, id, @did)
    end

    assert Hosts.count(h) == 1
  end

  test "an entry expires and is swept once heartbeats stop" do
    # ttl: -1 → read-expired instantly (no sleep to age it); heartbeat/3 is
    # map-presence only (TTL-blind), so it distinguishes 'filtered on read' from
    # 'swept from state'.
    h = start(ttl: -1, sweep: 60_000)
    {:ok, %{id: id}} = Hosts.register(h, @did, @valid)

    # past TTL for every read: out of the live view...
    assert Hosts.list(h) == []
    # ...but still in state — heartbeat still knows it
    assert :ok = Hosts.heartbeat(h, id, @did)

    # drive the sweep; the sync call is a barrier (mailbox order), so it reflects
    # post-sweep state without a sleep
    send(h, :sweep)
    assert {:error, :unknown} = Hosts.heartbeat(h, id, @did)
  end

  test "heartbeat on an unknown id is rejected" do
    h = start()
    assert {:error, :unknown} = Hosts.heartbeat(h, "deadbeefdeadbeef", @did)
  end

  test "deregister removes the host and is idempotent" do
    h = start()
    {:ok, %{id: id}} = Hosts.register(h, @did, @valid)

    assert :ok = Hosts.deregister(h, id, @did)
    assert Hosts.count(h) == 0
    assert :ok = Hosts.deregister(h, id, @did)
    assert {:error, :unknown} = Hosts.heartbeat(h, id, @did)
  end

  describe "validation" do
    test "rejects a url that isn't http(s)" do
      h = start()
      assert {:error, :invalid_url} = Hosts.register(h, @did, %{@valid | url: "ftp://nope"})
      assert {:error, :invalid_url} = Hosts.register(h, @did, %{@valid | url: "gpu-closet:8080"})
      assert {:error, :invalid_url} = Hosts.register(h, @did, %{@valid | url: "http://"})
    end

    test "rejects a blank or over-long name" do
      h = start()
      assert {:error, :invalid_name} = Hosts.register(h, @did, %{@valid | name: "   "})

      assert {:error, :invalid_name} =
               Hosts.register(h, @did, %{@valid | name: String.duplicate("x", 65)})
    end

    test "rejects a blank or over-long model" do
      h = start()
      assert {:error, :invalid_model} = Hosts.register(h, @did, %{@valid | model: ""})

      assert {:error, :invalid_model} =
               Hosts.register(h, @did, %{@valid | model: String.duplicate("m", 129)})
    end

    test "trims name and model before storing" do
      h = start()
      {:ok, _} = Hosts.register(h, @did, %{@valid | name: "  edge-box  ", model: "  llama3  "})
      assert [%{name: "edge-box", model: "llama3"}] = Hosts.list(h)
    end

    test "a blank or absent secret registers as not-served" do
      h = start()
      {:ok, _} = Hosts.register(h, @did, %{@valid | name: "a", secret: "   "})
      {:ok, _} = Hosts.register(h, @did, %{@valid | name: "b", secret: nil})
      {:ok, _} = Hosts.register(h, @did, %{@valid | name: "c"} |> Map.delete(:secret))
      assert Enum.all?(Hosts.list(h), &(&1.served == false))
    end

    test "accepts a fully string-keyed attrs map (the JSON params path), secret and all" do
      h = start(ttl: 60_000)

      attrs = %{
        "name" => "gpu-closet",
        "url" => "http://gpu-closet.tailnet.ts.net:8080",
        "model" => "qwen2.5-coder-7b",
        "secret" => "sk-from-json"
      }

      assert {:ok, %{id: _}} = Hosts.register(h, @did, attrs)
      assert [%{name: "gpu-closet", served: true}] = Hosts.list(h)
      assert %{secret: "sk-from-json"} = Hosts.served(h, "qwen2.5-coder-7b")
    end

    test "rejects a non-binary name and a non-binary model" do
      h = start()
      assert {:error, :invalid_name} = Hosts.register(h, @did, %{@valid | name: 42})
      assert {:error, :invalid_model} = Hosts.register(h, @did, %{@valid | model: nil})
    end
  end

  test "list returns hosts sorted by name" do
    h = start(ttl: 60_000)
    {:ok, _} = Hosts.register(h, @did, %{@valid | name: "zebra-rack"})
    {:ok, _} = Hosts.register(h, @did, %{@valid | name: "attic-mini"})

    assert h |> Hosts.list() |> Enum.map(& &1.name) == ["attic-mini", "zebra-rack"]
  end
end
