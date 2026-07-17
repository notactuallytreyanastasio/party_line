defmodule PartyLine.Memory.ClientTest do
  use ExUnit.Case, async: true

  alias PartyLine.Memory.Client

  # ── In-test stub of the deciduous API ─────────────────────────────────────
  #
  # A tiny plug served by Bandit on an ephemeral port. Unlike the ingest
  # stub, this one replies with a fixed (status, body) pair configured at
  # start, so each test can exercise exactly one envelope branch of the
  # client.

  defmodule Stub do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, _raw, conn} = read_body(conn)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(Keyword.fetch!(opts, :status), Jason.encode!(Keyword.fetch!(opts, :body)))
    end
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp start_stub(status, body) do
    {:ok, srv} =
      Bandit.start_link(plug: {Stub, status: status, body: body}, port: 0, startup_log: false)

    on_exit(fn -> if Process.alive?(srv), do: Process.exit(srv, :normal) end)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(srv)
    config(port)
  end

  defp config(port) do
    %{api_url: "http://127.0.0.1:#{port}", token: "test-token", graph: "party-line-root"}
  end

  defp envelope(data), do: %{"ok" => true, "data" => data}

  # ── add_node envelope branches ─────────────────────────────────────────────

  test "add_node returns the node id on a successful tool result" do
    config = start_stub(200, envelope(%{"is_error" => false, "result" => %{"node_id" => 42}}))

    assert {:ok, 42} = Client.add_node(config, %{node_type: "observation", title: "hi"})
  end

  test "add_node surfaces a tool-level failure as {:error, {:tool_error, result}}" do
    result = %{"message" => "no such branch"}
    config = start_stub(200, envelope(%{"is_error" => true, "result" => result}))

    assert {:error, {:tool_error, ^result}} = Client.add_node(config, %{title: "hi"})
  end

  test "add_node surfaces an ok:false envelope as {:error, {:api_error, error}}" do
    config = start_stub(200, %{"ok" => false, "error" => "unauthorized"})

    assert {:error, {:api_error, "unauthorized"}} = Client.add_node(config, %{title: "hi"})
  end

  test "add_node without a node_id in the result is {:error, {:missing_node_id, other}}" do
    config = start_stub(200, envelope(%{"is_error" => false, "result" => %{"nodes" => []}}))

    assert {:error, {:missing_node_id, %{"nodes" => []}}} = Client.add_node(config, %{title: "hi"})
  end

  test "a 2xx body that is not the documented envelope is {:error, {:unexpected_response, ..}}" do
    config = start_stub(200, %{"surprise" => true})

    assert {:error, {:unexpected_response, 200, %{"surprise" => true}}} =
             Client.add_node(config, %{title: "hi"})
  end

  # ── non-2xx statuses ───────────────────────────────────────────────────────

  test "a non-2xx status is {:error, {:http_status, status, body}} for every call" do
    body = %{"ok" => false, "error" => "boom"}
    config = start_stub(500, body)

    assert {:error, {:http_status, 500, ^body}} = Client.ensure_graph(config)
    assert {:error, {:http_status, 500, ^body}} = Client.add_node(config, %{title: "hi"})

    assert {:error, {:http_status, 500, ^body}} =
             Client.link_nodes(config, %{from_id: 1, to_id: 2, rationale: "follows"})
  end

  # ── transport failures: nothing here ever raises ──────────────────────────

  test "an unreachable api_url returns {:error, {:transport, _}} and never raises" do
    # grab an ephemeral port, then close it so nothing is listening there
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    config = config(port)

    assert {:error, {:transport, _}} = Client.ensure_graph(config)
    assert {:error, {:transport, _}} = Client.add_node(config, %{title: "hi"})

    assert {:error, {:transport, _}} =
             Client.link_nodes(config, %{from_id: 1, to_id: 2, rationale: "follows"})
  end

  # ── ensure_graph / link_nodes success shapes ───────────────────────────────

  test "ensure_graph is :ok on 200 (already exists)" do
    config = start_stub(200, envelope(%{"created" => false}))

    assert :ok = Client.ensure_graph(config)
  end

  test "ensure_graph is :ok on 201 (fresh create)" do
    config = start_stub(201, envelope(%{"created" => true}))

    assert :ok = Client.ensure_graph(config)
  end

  test "link_nodes is :ok on any successful tool result" do
    config = start_stub(200, envelope(%{"is_error" => false, "result" => %{}}))

    assert :ok = Client.link_nodes(config, %{from_id: 1, to_id: 2, rationale: "follows"})
  end
end
