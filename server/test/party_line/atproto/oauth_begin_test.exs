defmodule PartyLine.ATProto.OAuthBeginTest do
  @moduledoc """
  OAuth.begin/2 — the first half of the flow (resolve → auth-server metadata →
  PAR → authorize URL), which the token-endpoint tests in oauth_test.exs don't
  reach. One routing Bandit stub serves the whole chain plus a scriptable PAR
  endpoint (via an Agent) so the DPoP use_dpop_nonce retry and the par_failed
  branch run without the real network. DPoP proofs are real (aether crypto);
  the stub doesn't verify them, it just answers.
  """
  use ExUnit.Case, async: false

  alias PartyLine.ATProto.OAuth

  @client %{client_id: "http://localhost/client", redirect_uri: "http://127.0.0.1:4002/oauth/callback"}

  defmodule Stub do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      base = "http://#{conn.host}:#{conn.port}"

      case {conn.method, conn.request_path} do
        {"POST", "/par"} -> par(conn, agent)
        {"GET", path} -> get(conn, path, base)
        _ -> reply(conn, 404, %{"error" => "not_found"})
      end
    end

    # ── the resolve chain + auth-server metadata (all point back at the stub) ──
    defp get(conn, "/xrpc/com.atproto.identity.resolveHandle", _base),
      do: reply(conn, 200, %{"did" => "did:plc:xyz"})

    defp get(conn, "/did:plc:xyz", base),
      do:
        reply(conn, 200, %{
          "service" => [%{"type" => "AtprotoPersonalDataServer", "serviceEndpoint" => base}]
        })

    defp get(conn, "/.well-known/oauth-protected-resource", base),
      do: reply(conn, 200, %{"authorization_servers" => [base]})

    defp get(conn, "/.well-known/oauth-authorization-server", base),
      do:
        reply(conn, 200, %{
          "issuer" => base,
          "authorization_endpoint" => base <> "/authorize",
          "token_endpoint" => base <> "/token",
          "pushed_authorization_request_endpoint" => base <> "/par"
        })

    defp get(conn, _path, _base), do: reply(conn, 404, %{"error" => "not_found"})

    # ── PAR: scriptable, and it counts its calls ──────────────────────────────
    defp par(conn, agent) do
      {scenario, n} =
        Agent.get_and_update(agent, fn s -> {{s.scenario, s.calls + 1}, %{s | calls: s.calls + 1}} end)

      case {scenario, n} do
        {:nonce, 1} ->
          conn
          |> put_resp_header("dpop-nonce", "nonce-1")
          |> reply(400, %{"error" => "use_dpop_nonce"})

        {:failed, _} ->
          reply(conn, 400, %{"error" => "invalid_client_metadata"})

        _ ->
          # :ok, or the retried :nonce call
          conn
          |> put_resp_header("dpop-nonce", "nonce-1")
          |> reply(201, %{"request_uri" => "urn:ietf:params:oauth:request_uri:x"})
      end
    end

    defp reply(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  defp start_stub(scenario) do
    {:ok, agent} = Agent.start_link(fn -> %{scenario: scenario, calls: 0} end)
    {:ok, srv} = Bandit.start_link(plug: {Stub, agent: agent}, port: 0, startup_log: false)
    on_exit(fn -> if Process.alive?(srv), do: Process.exit(srv, :normal) end)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(srv)
    base = "http://127.0.0.1:#{port}"

    Application.put_env(:party_line, :atproto_resolver, base)
    Application.put_env(:party_line, :atproto_plc, base)

    on_exit(fn ->
      Application.delete_env(:party_line, :atproto_resolver)
      Application.delete_env(:party_line, :atproto_plc)
    end)

    {agent, base}
  end

  test "begin resolves, PARs, and returns the authorize URL + a pending session" do
    {_agent, base} = start_stub(:ok)

    assert {:ok, url, session} = OAuth.begin("alice.test", client: @client)

    assert String.starts_with?(url, base <> "/authorize?")
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["client_id"] == @client.client_id
    assert query["request_uri"] == "urn:ietf:params:oauth:request_uri:x"

    assert session.did == "did:plc:xyz"
    assert session.issuer == base
    assert session.token_endpoint == base <> "/token"
    assert is_binary(session.state) and session.state != ""
    assert is_binary(session.pkce_verifier)
  end

  test "a use_dpop_nonce challenge is retried once with the handed-out nonce" do
    {agent, _base} = start_stub(:nonce)

    assert {:ok, _url, session} = OAuth.begin("alice.test", client: @client)
    # exactly two PAR calls: the challenge, then the retry that carries the nonce
    assert Agent.get(agent, & &1.calls) == 2
    assert session.dpop_nonce == "nonce-1"
  end

  test "a PAR rejection surfaces as {:par_failed, body}" do
    {_agent, _base} = start_stub(:failed)
    assert {:error, {:par_failed, %{"error" => "invalid_client_metadata"}}} =
             OAuth.begin("alice.test", client: @client)
  end
end
