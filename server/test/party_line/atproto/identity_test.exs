defmodule PartyLine.ATProto.IdentityTest do
  @moduledoc """
  The handle → DID → PDS → auth-server resolve chain, run against a single
  Bandit stub that serves every hop. The resolver/plc bases are pointed at the
  stub via config; the PDS and auth-server URLs come from the response bodies,
  so the stub embeds its own address (from the request) and serves those too.

  A `scenario` selects which shape the DID doc / protected-resource return, so
  the not-found branches are exercised without the real network.
  """
  use ExUnit.Case, async: false

  alias PartyLine.ATProto.Identity

  defmodule Stub do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      scenario = Keyword.fetch!(opts, :scenario)
      base = "http://#{conn.host}:#{conn.port}"
      {status, body} = respond(scenario, conn.request_path, base)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    # handle → did (the resolveHandle xrpc)
    defp respond(_s, "/xrpc/com.atproto.identity.resolveHandle", _base),
      do: {200, %{"did" => "did:plc:xyz"}}

    # did → doc; the PDS is a service entry pointing back at this stub
    defp respond(:no_pds, "/did:plc:xyz", _base),
      do: {200, %{"service" => [%{"type" => "SomethingElse"}]}}

    defp respond(_s, "/did:plc:xyz", base),
      do:
        {200,
         %{
           "service" => [
             %{"type" => "AtprotoPersonalDataServer", "serviceEndpoint" => base}
           ]
         }}

    # PDS → auth server (the protected-resource doc)
    defp respond(:no_auth_server, "/.well-known/oauth-protected-resource", _base),
      do: {200, %{"authorization_servers" => []}}

    defp respond(_s, "/.well-known/oauth-protected-resource", base),
      do: {200, %{"authorization_servers" => [base]}}

    defp respond(_s, _path, _base), do: {404, %{"error" => "not_found"}}
  end

  defp start_stub(scenario) do
    {:ok, srv} = Bandit.start_link(plug: {Stub, scenario: scenario}, port: 0, startup_log: false)
    on_exit(fn -> if Process.alive?(srv), do: Process.exit(srv, :normal) end)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(srv)
    base = "http://127.0.0.1:#{port}"

    Application.put_env(:party_line, :atproto_resolver, base)
    Application.put_env(:party_line, :atproto_plc, base)

    on_exit(fn ->
      Application.delete_env(:party_line, :atproto_resolver)
      Application.delete_env(:party_line, :atproto_plc)
    end)

    base
  end

  test "resolves a handle through the whole chain" do
    base = start_stub(:ok)

    assert {:ok, ident} = Identity.resolve("alice.test")
    assert ident.did == "did:plc:xyz"
    assert ident.handle == "alice.test"
    assert ident.pds == base
    assert ident.auth_server == base
  end

  test "a DID with no AtprotoPersonalDataServer service is :no_pds" do
    start_stub(:no_pds)
    assert {:error, :no_pds} = Identity.resolve("alice.test")
  end

  test "a PDS advertising no authorization server is :no_auth_server" do
    start_stub(:no_auth_server)
    assert {:error, :no_auth_server} = Identity.resolve("alice.test")
  end

  test "a did:plc input skips handle resolution and still resolves" do
    base = start_stub(:ok)
    assert {:ok, %{did: "did:plc:xyz", handle: nil, pds: ^base}} = Identity.resolve("did:plc:xyz")
  end
end
