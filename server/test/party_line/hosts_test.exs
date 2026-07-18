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

  defp start(opts \\ []) do
    start_supervised!(
      {Hosts, Keyword.merge([ttl: 60, sweep: 20, name: nil], opts)},
      id: {Hosts, System.unique_integer()}
    )
  end

  test "register returns a 16-hex id and the ttl in seconds" do
    h = start(ttl: 90_000)
    assert {:ok, %{id: id, ttl_seconds: 90}} = Hosts.register(h, @valid)
    assert id =~ ~r/\A[0-9a-f]{16}\z/
  end

  test "a registered host shows up in the live list and count" do
    h = start()
    {:ok, %{id: id}} = Hosts.register(h, @valid)

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

  test "served/2 resolves a proxyable host by model or name to its private url + secret" do
    h = start()
    {:ok, _} = Hosts.register(h, @valid)

    assert %{url: url, secret: "sk-host-secret", model: "qwen2.5-coder-7b", name: "gpu-closet"} =
             Hosts.served(h, "qwen2.5-coder-7b")

    assert url == @valid.url
    # by name too, case-insensitive
    assert %{secret: "sk-host-secret"} = Hosts.served(h, "GPU-CLOSET")
    # unknown handle → nil
    assert Hosts.served(h, "no-such-model") == nil
  end

  test "a host that registered no secret is listed but not proxyable" do
    h = start()
    {:ok, _} = Hosts.register(h, Map.delete(@valid, :secret))

    assert [%{served: false}] = Hosts.list(h)
    assert Hosts.served(h, "qwen2.5-coder-7b") == nil
  end

  test "heartbeat keeps an entry alive past the TTL" do
    h = start(ttl: 60, sweep: 15)
    {:ok, %{id: id}} = Hosts.register(h, @valid)

    # Beat well past one TTL's worth of time; the entry survives.
    for _ <- 1..5 do
      Process.sleep(25)
      assert :ok = Hosts.heartbeat(h, id)
    end

    assert Hosts.count(h) == 1
  end

  test "an entry expires and is swept once heartbeats stop" do
    h = start(ttl: 40, sweep: 15)
    {:ok, %{id: id}} = Hosts.register(h, @valid)
    assert Hosts.count(h) == 1

    # No heartbeats: falls out of the live view immediately past TTL...
    Process.sleep(60)
    assert Hosts.list(h) == []

    # ...and gets swept from state, so heartbeat no longer knows it.
    Process.sleep(40)
    assert {:error, :unknown} = Hosts.heartbeat(h, id)
  end

  test "heartbeat on an unknown id is rejected" do
    h = start()
    assert {:error, :unknown} = Hosts.heartbeat(h, "deadbeefdeadbeef")
  end

  test "deregister removes the host and is idempotent" do
    h = start()
    {:ok, %{id: id}} = Hosts.register(h, @valid)

    assert :ok = Hosts.deregister(h, id)
    assert Hosts.count(h) == 0
    assert :ok = Hosts.deregister(h, id)
    assert {:error, :unknown} = Hosts.heartbeat(h, id)
  end

  describe "validation" do
    test "rejects a url that isn't http(s)" do
      h = start()
      assert {:error, :invalid_url} = Hosts.register(h, %{@valid | url: "ftp://nope"})
      assert {:error, :invalid_url} = Hosts.register(h, %{@valid | url: "gpu-closet:8080"})
      assert {:error, :invalid_url} = Hosts.register(h, %{@valid | url: "http://"})
    end

    test "rejects a blank or over-long name" do
      h = start()
      assert {:error, :invalid_name} = Hosts.register(h, %{@valid | name: "   "})

      assert {:error, :invalid_name} =
               Hosts.register(h, %{@valid | name: String.duplicate("x", 65)})
    end

    test "rejects a blank or over-long model" do
      h = start()
      assert {:error, :invalid_model} = Hosts.register(h, %{@valid | model: ""})

      assert {:error, :invalid_model} =
               Hosts.register(h, %{@valid | model: String.duplicate("m", 129)})
    end

    test "trims name and model before storing" do
      h = start()
      {:ok, _} = Hosts.register(h, %{@valid | name: "  edge-box  ", model: "  llama3  "})
      assert [%{name: "edge-box", model: "llama3"}] = Hosts.list(h)
    end

    test "a blank or absent secret registers as not-served" do
      h = start()
      {:ok, _} = Hosts.register(h, %{@valid | name: "a", secret: "   "})
      {:ok, _} = Hosts.register(h, %{@valid | name: "b", secret: nil})
      {:ok, _} = Hosts.register(h, %{@valid | name: "c"} |> Map.delete(:secret))
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

      assert {:ok, %{id: _}} = Hosts.register(h, attrs)
      assert [%{name: "gpu-closet", served: true}] = Hosts.list(h)
      assert %{secret: "sk-from-json"} = Hosts.served(h, "gpu-closet")
    end

    test "rejects a non-binary name and a non-binary model" do
      h = start()
      assert {:error, :invalid_name} = Hosts.register(h, %{@valid | name: 42})
      assert {:error, :invalid_model} = Hosts.register(h, %{@valid | model: nil})
    end
  end

  test "list returns hosts sorted by name" do
    h = start(ttl: 60_000)
    {:ok, _} = Hosts.register(h, %{@valid | name: "zebra-rack"})
    {:ok, _} = Hosts.register(h, %{@valid | name: "attic-mini"})

    assert h |> Hosts.list() |> Enum.map(& &1.name) == ["attic-mini", "zebra-rack"]
  end
end
