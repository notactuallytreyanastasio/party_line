defmodule PartyLine.ATProto.OAuthTest do
  use ExUnit.Case, async: true

  alias Aether.ATProto.Crypto.DPoP
  alias PartyLine.ATProto.OAuth

  # ── In-test stub of an atproto token endpoint ─────────────────────────────
  #
  # A tiny plug served by Bandit on an ephemeral port (mirrors the Stub in
  # memory/ingest_test.exs). It records every call (method, path, decoded form
  # body, DPoP header) into an Agent and answers from a scriptable response
  # queue so the DPoP use_dpop_nonce retry sequences can be exercised.

  defmodule Stub do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      {:ok, raw, conn} = read_body(conn)

      call = %{
        method: conn.method,
        path: conn.request_path,
        form: URI.decode_query(raw),
        dpop: conn |> get_req_header("dpop") |> List.first()
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

  # ── Fixtures ───────────────────────────────────────────────────────────────

  @client %{
    client_id:
      "http://localhost?" <>
        URI.encode_query(%{
          "redirect_uri" => "http://127.0.0.1:4002/oauth/callback",
          "scope" => "atproto transition:generic"
        }),
    redirect_uri: "http://127.0.0.1:4002/oauth/callback"
  }

  defp start_stub(responses) do
    {:ok, agent} = Agent.start_link(fn -> %{calls: [], responses: responses} end)
    {:ok, srv} = Bandit.start_link(plug: {Stub, agent: agent}, port: 0, startup_log: false)
    on_exit(fn -> if Process.alive?(srv), do: Process.exit(srv, :normal) end)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(srv)
    {agent, "http://127.0.0.1:#{port}/oauth/token"}
  end

  defp calls(agent), do: Agent.get(agent, & &1.calls)

  defp session(token_endpoint, overrides \\ %{}) do
    Map.merge(
      %{
        did: "did:plc:horsedentist123",
        handle: "horse-dentist.example",
        pds: "https://pds.example",
        issuer: "https://auth.example",
        token_endpoint: token_endpoint,
        state: "state-abc",
        pkce_verifier: "verifier-xyz",
        dpop_key: DPoP.generate_key(),
        dpop_nonce: nil
      },
      overrides
    )
  end

  defp callback_params(session, overrides \\ %{}) do
    Map.merge(
      %{
        :client => @client,
        "state" => session.state,
        "iss" => session.issuer,
        "code" => "code-123"
      },
      overrides
    )
  end

  defp tokens_fixture(token_endpoint, overrides \\ %{}) do
    Map.merge(
      %{
        did: "did:plc:horsedentist123",
        pds: "https://pds.example",
        token_endpoint: token_endpoint,
        access_token: "at-old",
        refresh_token: "rt-old",
        scope: "atproto transition:generic",
        expires_at: System.system_time(:second),
        dpop_key: DPoP.generate_key(),
        dpop_nonce: "seed-nonce"
      },
      overrides
    )
  end

  defp token_response(overrides \\ %{}) do
    Map.merge(
      %{
        "sub" => "did:plc:horsedentist123",
        "token_type" => "DPoP",
        "access_token" => "at-1",
        "refresh_token" => "rt-1",
        "scope" => "atproto transition:generic",
        "expires_in" => 3600
      },
      overrides
    )
  end

  # a DPoP proof is a compact JWT; the nonce rides in the payload claims
  defp proof_claims(proof) do
    [_header, payload, _sig] = String.split(proof, ".")
    payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  # ── finish/2 guards ────────────────────────────────────────────────────────

  describe "finish/2 callback verification" do
    test "a state mismatch is rejected before any token HTTP call" do
      {agent, endpoint} = start_stub([])
      session = session(endpoint)

      params = callback_params(session, %{"state" => "evil-other-state"})
      assert {:error, :state_mismatch} = OAuth.finish(session, params)
      assert calls(agent) == []
    end

    test "an iss that differs from the session issuer is rejected without HTTP" do
      {agent, endpoint} = start_stub([])
      session = session(endpoint)

      params = callback_params(session, %{"iss" => "https://impostor.example"})
      assert {:error, :issuer_mismatch} = OAuth.finish(session, params)
      assert calls(agent) == []
    end

    test "an absent iss skips the issuer check entirely" do
      {_agent, endpoint} = start_stub([%{status: 200, body: token_response()}])
      session = session(endpoint)

      params = session |> callback_params() |> Map.delete("iss")
      assert {:ok, _tokens} = OAuth.finish(session, params)
    end
  end

  # ── finish/2 code exchange ─────────────────────────────────────────────────

  describe "finish/2 token exchange" do
    test "happy path: posts the authorization-code form with a verifiable DPoP proof and packs tokens" do
      {agent, endpoint} = start_stub([%{status: 200, body: token_response()}])
      session = session(endpoint, %{dpop_nonce: "seed-nonce"})

      assert {:ok, tokens} = OAuth.finish(session, callback_params(session))

      assert [call] = calls(agent)
      assert call.method == "POST"

      assert call.form == %{
               "grant_type" => "authorization_code",
               "code" => "code-123",
               "code_verifier" => "verifier-xyz",
               "redirect_uri" => @client.redirect_uri,
               "client_id" => @client.client_id
             }

      # the proof is a real ES256 JWT bound to POST + the token endpoint,
      # carrying the session nonce
      assert {:ok, _jwk} = DPoP.verify_proof(call.dpop, "POST", endpoint)
      assert proof_claims(call.dpop)["nonce"] == "seed-nonce"

      assert tokens.did == "did:plc:horsedentist123"
      assert tokens.pds == "https://pds.example"
      assert tokens.token_endpoint == endpoint
      assert tokens.access_token == "at-1"
      assert tokens.refresh_token == "rt-1"
      assert tokens.scope == "atproto transition:generic"
      assert tokens.dpop_key == session.dpop_key
      # no dpop-nonce header on the 200 → the nonce we sent is retained
      assert tokens.dpop_nonce == "seed-nonce"
      assert_in_delta tokens.expires_at, System.system_time(:second) + 3600, 5
    end

    test "a sub that differs from the session DID is a subject mismatch" do
      {_agent, endpoint} =
        start_stub([%{status: 200, body: token_response(%{"sub" => "did:plc:someoneelse"})}])

      session = session(endpoint)

      assert {:error, :subject_mismatch} = OAuth.finish(session, callback_params(session))
    end

    test "a nil session DID (bare-handle begin) accepts the response sub as the identity" do
      {_agent, endpoint} = start_stub([%{status: 200, body: token_response()}])
      session = session(endpoint, %{did: nil})

      assert {:ok, tokens} = OAuth.finish(session, callback_params(session))
      assert tokens.did == "did:plc:horsedentist123"
    end

    test "expires_at falls back to now+600 when the response omits expires_in" do
      resp = token_response() |> Map.delete("expires_in")
      {_agent, endpoint} = start_stub([%{status: 200, body: resp}])
      session = session(endpoint)

      assert {:ok, tokens} = OAuth.finish(session, callback_params(session))
      assert_in_delta tokens.expires_at, System.system_time(:second) + 600, 5
    end

    test "use_dpop_nonce with a fresh nonce retries exactly once and succeeds" do
      {agent, endpoint} =
        start_stub([
          %{
            status: 400,
            body: %{"error" => "use_dpop_nonce"},
            headers: [{"dpop-nonce", "fresh-1"}]
          },
          %{status: 200, body: token_response(), headers: [{"dpop-nonce", "final-nonce"}]}
        ])

      session = session(endpoint)

      assert {:ok, tokens} = OAuth.finish(session, callback_params(session))

      assert [first, second] = calls(agent)
      # first attempt carried no nonce; the retry carries the server's
      refute Map.has_key?(proof_claims(first.dpop), "nonce")
      assert proof_claims(second.dpop)["nonce"] == "fresh-1"
      assert {:ok, _jwk} = DPoP.verify_proof(second.dpop, "POST", endpoint)

      # Req hands header values back as lists — the packed nonce must be the
      # bare binary, not ["final-nonce"]
      assert tokens.dpop_nonce == "final-nonce"
    end

    test "use_dpop_nonce echoing the SAME nonce stops with :dpop_nonce_loop instead of looping" do
      {agent, endpoint} =
        start_stub([
          %{
            status: 400,
            body: %{"error" => "use_dpop_nonce"},
            headers: [{"dpop-nonce", "stale"}]
          }
        ])

      session = session(endpoint, %{dpop_nonce: "stale"})

      assert {:error, :dpop_nonce_loop} = OAuth.finish(session, callback_params(session))
      assert length(calls(agent)) == 1
    end

    test "use_dpop_nonce with NO dpop-nonce header stops with :dpop_nonce_loop" do
      {agent, endpoint} = start_stub([%{status: 400, body: %{"error" => "use_dpop_nonce"}}])
      session = session(endpoint)

      assert {:error, :dpop_nonce_loop} = OAuth.finish(session, callback_params(session))
      assert length(calls(agent)) == 1
    end

    test "a non-nonce error body comes back as {:token_failed, body}" do
      body = %{"error" => "invalid_grant", "error_description" => "code already used"}
      {_agent, endpoint} = start_stub([%{status: 400, body: body}])
      session = session(endpoint)

      assert {:error, {:token_failed, %{"error" => "invalid_grant"}}} =
               OAuth.finish(session, callback_params(session))
    end
  end

  # ── refresh/2 ──────────────────────────────────────────────────────────────

  describe "refresh/2" do
    test "posts the refresh_token grant and rotates to the NEW refresh token" do
      resp = token_response(%{"access_token" => "at-new", "refresh_token" => "rt-new"})
      {agent, endpoint} = start_stub([%{status: 200, body: resp}])
      tokens = tokens_fixture(endpoint)

      assert {:ok, refreshed} = OAuth.refresh(tokens, client: @client)

      assert [call] = calls(agent)

      assert call.form == %{
               "grant_type" => "refresh_token",
               "refresh_token" => "rt-old",
               "client_id" => @client.client_id
             }

      assert {:ok, _jwk} = DPoP.verify_proof(call.dpop, "POST", endpoint)

      # single-use rotation: keeping rt-old would brick the next refresh
      assert refreshed.refresh_token == "rt-new"
      assert refreshed.access_token == "at-new"
      assert refreshed.did == tokens.did
    end

    test "a 4xx body (e.g. invalid_grant after reuse) propagates as {:token_failed, body}" do
      {_agent, endpoint} = start_stub([%{status: 400, body: %{"error" => "invalid_grant"}}])
      tokens = tokens_fixture(endpoint)

      assert {:error, {:token_failed, %{"error" => "invalid_grant"}}} =
               OAuth.refresh(tokens, client: @client)
    end

    test "seeds the DPoP nonce from tokens and follows the use_dpop_nonce retry path" do
      resp = token_response(%{"access_token" => "at-new", "refresh_token" => "rt-new"})

      {agent, endpoint} =
        start_stub([
          %{
            status: 400,
            body: %{"error" => "use_dpop_nonce"},
            headers: [{"dpop-nonce", "fresh-r"}]
          },
          %{status: 200, body: resp}
        ])

      tokens = tokens_fixture(endpoint, %{dpop_nonce: "seed-nonce"})

      assert {:ok, refreshed} = OAuth.refresh(tokens, client: @client)

      assert [first, second] = calls(agent)
      assert proof_claims(first.dpop)["nonce"] == "seed-nonce"
      assert proof_claims(second.dpop)["nonce"] == "fresh-r"
      assert refreshed.refresh_token == "rt-new"
      assert refreshed.dpop_nonce == "fresh-r"
    end
  end
end
