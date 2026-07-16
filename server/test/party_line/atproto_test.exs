defmodule PartyLine.ATProtoTest do
  use ExUnit.Case, async: true

  alias PartyLine.ATProto.{Client, Sessions}

  describe "client metadata" do
    test "is a valid public-client document" do
      meta = Client.metadata()
      assert meta["dpop_bound_access_tokens"] == true
      assert meta["token_endpoint_auth_method"] == "none"
      assert meta["response_types"] == ["code"]
      assert "authorization_code" in meta["grant_types"]
      assert "refresh_token" in meta["grant_types"]
      assert meta["scope"] =~ "atproto"
      assert [redirect] = meta["redirect_uris"]
      assert redirect =~ "/oauth/callback"
    end

    test "dev config uses the loopback client with a 127.0.0.1 redirect" do
      cfg = Client.config()
      # test/dev base is localhost → special loopback client, but the
      # redirect must be the loopback IP (RFC 8252), never "localhost"
      assert cfg.client_id =~ "http://localhost"
      assert cfg.client_id =~ "redirect_uri="
      assert cfg.redirect_uri =~ "127.0.0.1"
      assert cfg.redirect_uri =~ "/oauth/callback"
      refute cfg.redirect_uri =~ "//localhost"
    end
  end

  describe "dpop proofs (via aether)" do
    alias Aether.ATProto.Crypto.DPoP

    test "a proof is a verifiable JWT bound to method+url" do
      key = DPoP.generate_key()
      proof = DPoP.generate_proof("POST", "https://pds.example/par", key, "nonce-123")
      assert is_binary(proof)
      assert {:ok, _claims} = DPoP.verify_proof(proof, "POST", "https://pds.example/par")
    end

    test "the key is a JSON-safe map (session-serializable)" do
      key = DPoP.generate_key()
      assert Enum.all?(Map.keys(key), &is_binary/1)
      assert {:ok, _} = Jason.encode(key)
    end
  end

  describe "sessions" do
    test "pending sessions are single-use" do
      {:ok, s} = Sessions.start_link(name: nil)
      # exercise the real named server the app starts
      id = Sessions.put_pending(%{state: "abc", pkce_verifier: "v"})
      assert %{state: "abc"} = Sessions.take_pending(id)
      assert Sessions.take_pending(id) == nil
      _ = s
    end

    test "tokens round-trip and delete" do
      id = Sessions.put_tokens(%{did: "did:plc:x", access_token: "at"})
      assert %{did: "did:plc:x"} = Sessions.get_tokens(id)
      Sessions.delete_tokens(id)
      assert Sessions.get_tokens(id) == nil
    end
  end
end
