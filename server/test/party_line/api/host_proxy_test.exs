defmodule PartyLine.API.HostProxyTest do
  @moduledoc """
  The real lent-model proxy — the sole path from the internet to a lent model,
  and the only holder of the host secret. Tests run it against a Bandit stub on
  an ephemeral port (the pattern from atproto/oauth_test) that records the
  request and answers from a scripted queue.
  """
  use ExUnit.Case, async: true

  alias PartyLine.API.HostProxy

  defmodule Stub do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      {:ok, raw, conn} = read_body(conn)

      call = %{
        method: conn.method,
        path: conn.request_path,
        auth: conn |> get_req_header("authorization") |> List.first(),
        body: Jason.decode!(raw)
      }

      response =
        Agent.get_and_update(agent, fn s ->
          {resp, rest} = pop(s.responses)
          {resp, %{s | calls: s.calls ++ [call], responses: rest}}
        end)

      response
      |> Map.get(:headers, [])
      |> Enum.reduce(conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
      |> put_resp_content_type("application/json")
      |> send_resp(response.status, Jason.encode!(response.body))
    end

    defp pop([resp | rest]), do: {resp, rest}
    defp pop([]), do: {%{status: 500, body: %{"error" => "stub_exhausted"}}, []}
  end

  defp start_stub(responses) do
    {:ok, agent} = Agent.start_link(fn -> %{calls: [], responses: responses} end)
    {:ok, srv} = Bandit.start_link(plug: {Stub, agent: agent}, port: 0, startup_log: false)
    on_exit(fn -> if Process.alive?(srv), do: Process.exit(srv, :normal) end)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(srv)
    {agent, "http://127.0.0.1:#{port}"}
  end

  defp host(url), do: %{url: url, secret: "sk-host", model: "qwen-7b", name: "gpu-closet"}

  test "posts to /v1/chat/completions with the host's bearer secret; returns the body" do
    completion = %{"object" => "chat.completion", "choices" => [%{"message" => %{"content" => "hi"}}]}
    {agent, url} = start_stub([%{status: 200, body: completion}])

    assert {:ok, ^completion} =
             HostProxy.chat(host(url), %{"messages" => [%{"role" => "user", "content" => "yo"}]})

    # the only place the host secret is used — it must reach the host, and only it
    [call] = Agent.get(agent, & &1.calls)
    assert call.method == "POST"
    assert call.path == "/v1/chat/completions"
    assert call.auth == "Bearer sk-host"
    assert call.body["messages"] == [%{"role" => "user", "content" => "yo"}]
  end

  test "a trailing slash on the host url doesn't double the path" do
    {agent, url} = start_stub([%{status: 200, body: %{"object" => "chat.completion"}}])
    assert {:ok, _} = HostProxy.chat(host(url <> "/"), %{"messages" => []})
    assert [%{path: "/v1/chat/completions"}] = Agent.get(agent, & &1.calls)
  end

  test "a non-2xx status is {:error, {:host_status, n}}" do
    {_agent, url} = start_stub([%{status: 500, body: %{"error" => "boom"}}])
    assert {:error, {:host_status, 500}} = HostProxy.chat(host(url), %{"messages" => []})
  end

  test "an unreachable host is {:error, :host_unreachable}" do
    # grab a port then release it, so nothing is listening there
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :ok = :gen_tcp.close(sock)

    assert {:error, :host_unreachable} =
             HostProxy.chat(host("http://127.0.0.1:#{port}"), %{"messages" => []})
  end

  test "a redirect is NOT followed — the SSRF defense holds" do
    # the host tries to bounce us to a second endpoint; redirect: false means we
    # never chase it (an allowlisted url could otherwise 3xx to an internal one)
    {redirect_agent, redirect_url} = start_stub([%{status: 200, body: %{"pwned" => true}}])

    {_agent, url} =
      start_stub([
        %{status: 302, headers: [{"location", redirect_url <> "/v1/chat/completions"}], body: %{}}
      ])

    assert {:error, {:host_status, 302}} = HostProxy.chat(host(url), %{"messages" => []})
    # the redirect target was never contacted
    assert Agent.get(redirect_agent, & &1.calls) == []
  end
end
