defmodule PartyLine.Memory.BrokerTest do
  @moduledoc """
  The broker is a boundary, so these are mostly about what a leased bot
  *cannot* do. A room's graph having many authors is the point; a stranger's
  laptop being able to erase what the other authors wrote is not.
  """
  use ExUnit.Case, async: true

  alias PartyLine.Memory.Broker

  # Records every request so a test can prove which graph was actually hit.
  defmodule Daemon do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      send(Keyword.fetch!(opts, :test), {:daemon, conn.method, conn.request_path, body})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"ok":true,"data":{"is_error":false,"result":{"node_id":7}}}))
    end
  end

  defp daemon do
    {:ok, srv} = Bandit.start_link(plug: {Daemon, test: self()}, port: 0, startup_log: false)
    on_exit(fn -> if Process.alive?(srv), do: Process.exit(srv, :normal) end)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(srv)
    %{api_url: "http://127.0.0.1:#{port}", token: "t", graph: nil}
  end

  describe "the graph is the room, and the bot doesn't get a say" do
    test "a call lands on the room the caller named" do
      config = daemon()

      assert {:ok, _} =
               Broker.call("room-observatory", "add_node", %{title: "the moon again"},
                 config: config
               )

      # the graph is created if it isn't there yet — a bot's first write may
      # beat the server's first ingest
      assert_receive {:daemon, "PUT", "/api/v1/graphs/plr-room-observatory", _}
      assert_receive {:daemon, "POST", "/api/v1/graphs/plr-room-observatory/tools/add_node", body}
      assert body =~ "the moon again"
    end

    test "a bot cannot reach another room, because it never names one" do
      # there is no argument for it: the room comes from the socket's state.
      # This is a design assertion — call/4's signature is the boundary.
      assert {:arity, 4} in :erlang.fun_info(&Broker.call/4)
    end
  end

  describe "append and read, never destroy" do
    test "the tools a persona needs are allowed" do
      for tool <- ~w(add_node link_nodes list_nodes search_nodes show_node) do
        assert tool in Broker.allowed_tools()
      end
    end

    test "nothing that removes what another author wrote is allowed" do
      config = daemon()

      for tool <- ~w(delete_node unlink_nodes update_status update_prompt) do
        assert {:error, {:tool_not_allowed, ^tool}} =
                 Broker.call("room-default", tool, %{}, config: config)

        refute tool in Broker.allowed_tools()
      end

      # and nothing reached the daemon
      refute_receive {:daemon, _, _, _}, 50
    end

    test "an invented tool is refused before it can reach the daemon" do
      config = daemon()

      assert {:error, {:tool_not_allowed, "rm_rf"}} =
               Broker.call("room-default", "rm_rf", %{}, config: config)

      refute_receive {:daemon, _, _, _}, 50
    end
  end

  describe "no daemon" do
    test "memory being off is a plain answer, not a crash" do
      assert {:error, :memory_disabled} =
               Broker.call("room-default", "add_node", %{}, config: nil)
    end

    test "a forbidden tool is forbidden even when memory is off" do
      # otherwise the refusal is incidental, and turning memory on would
      # quietly turn `delete_node` into a real delete
      assert {:error, {:tool_not_allowed, "delete_node"}} =
               Broker.call("room-default", "delete_node", %{}, config: nil)
    end
  end
end
