defmodule PartyLine.ATProto.OAuth do
  @moduledoc """
  The atproto OAuth authorization-code flow for a **public** client
  (`token_endpoint_auth_method: none`) — PKCE + PAR + DPoP, no client
  secret.

  Crypto primitives (DPoP keypair + proofs, PKCE) come from
  `aether_atproto`; the flow orchestration (identity resolution, PAR,
  authorize URL, token exchange, refresh) is here because no library
  provides it. `PartyLine.ATProto.Identity` does the HTTP resolution
  (aether's DID resolver mishandles 200s, so we keep our own).

  Flow:
    1. `begin/2`  — resolve identity, mint session crypto, PAR, return the
                    authorize URL to send the browser to.
    2. (browser round-trip; the PDS authenticates the user)
    3. `finish/2` — exchange the returned code for DPoP-bound tokens.
  """

  @behaviour PartyLine.ATProto.OAuth.Behaviour

  alias Aether.ATProto.Crypto.{DPoP, PKCE}
  alias PartyLine.ATProto.Identity

  @scope "atproto transition:generic"

  @doc "Start the flow. Returns `{:ok, authorize_url, session}`."
  @impl true
  def begin(handle_or_did, opts) do
    client = Keyword.fetch!(opts, :client)

    with {:ok, ident} <- Identity.resolve(handle_or_did),
         {:ok, meta} <- Identity.auth_server_metadata(ident.auth_server) do
      dpop_key = DPoP.generate_key()
      pkce = PKCE.generate()
      state = random(32)

      params = %{
        "client_id" => client.client_id,
        "response_type" => "code",
        "code_challenge" => pkce.code_challenge,
        "code_challenge_method" => pkce.code_challenge_method,
        "state" => state,
        "scope" => @scope,
        "redirect_uri" => client.redirect_uri,
        "login_hint" => ident.handle || ident.did
      }

      with {:ok, request_uri, nonce} <- par(meta, dpop_key, params) do
        url =
          meta["authorization_endpoint"] <>
            "?" <>
            URI.encode_query(%{"client_id" => client.client_id, "request_uri" => request_uri})

        session = %{
          did: ident.did,
          handle: ident.handle,
          pds: ident.pds,
          issuer: meta["issuer"],
          token_endpoint: meta["token_endpoint"],
          state: state,
          pkce_verifier: pkce.code_verifier,
          dpop_key: dpop_key,
          dpop_nonce: nonce
        }

        {:ok, url, session}
      end
    end
  end

  @doc """
  Complete the flow. `params` is the callback query plus a `:client`.
  Verifies `state`/`iss`, exchanges the code, returns `{:ok, tokens}`.
  """
  @impl true
  def finish(session, params) do
    client = params.client

    cond do
      params["state"] != session.state ->
        {:error, :state_mismatch}

      params["iss"] && params["iss"] != session.issuer ->
        {:error, :issuer_mismatch}

      true ->
        exchange(session, %{
          "grant_type" => "authorization_code",
          "code" => params["code"],
          "code_verifier" => session.pkce_verifier,
          "redirect_uri" => client.redirect_uri,
          "client_id" => client.client_id
        })
    end
  end

  @doc "Refresh an access token (single-use refresh token → new pair)."
  @impl true
  def refresh(tokens, opts) do
    client = Keyword.fetch!(opts, :client)

    exchange(tokens, %{
      "grant_type" => "refresh_token",
      "refresh_token" => tokens.refresh_token,
      "client_id" => client.client_id
    })
  end

  # ── PAR ─────────────────────────────────────────────────────────────────

  defp par(meta, dpop_key, params, nonce \\ nil) do
    endpoint = meta["pushed_authorization_request_endpoint"]
    proof = DPoP.generate_proof("POST", endpoint, dpop_key, nonce)

    case post_form(endpoint, params, proof) do
      {:ok, %{status: status, body: %{"request_uri" => request_uri}} = resp}
      when status in [200, 201] ->
        {:ok, request_uri, dpop_nonce(resp)}

      {:ok, %{status: 400, body: %{"error" => "use_dpop_nonce"}} = resp} when is_nil(nonce) ->
        # the first PAR carries no nonce; the server hands one out, retry once
        par(meta, dpop_key, params, dpop_nonce(resp))

      {:ok, %{body: body}} ->
        {:error, {:par_failed, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── token endpoint (code exchange + refresh share this) ───────────────────

  defp exchange(session, body, nonce \\ nil) do
    nonce = nonce || session.dpop_nonce
    endpoint = session.token_endpoint
    proof = DPoP.generate_proof("POST", endpoint, session.dpop_key, nonce)

    case post_form(endpoint, body, proof) do
      {:ok, %{status: 200, body: resp} = http} ->
        verify_and_pack(session, resp, dpop_nonce(http) || nonce)

      {:ok, %{status: 400, body: %{"error" => "use_dpop_nonce"}} = http} ->
        fresh = dpop_nonce(http)

        if fresh && fresh != nonce,
          do: exchange(session, body, fresh),
          else: {:error, :dpop_nonce_loop}

      {:ok, %{body: resp}} ->
        {:error, {:token_failed, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_and_pack(session, resp, nonce) do
    if session.did && resp["sub"] != session.did do
      {:error, :subject_mismatch}
    else
      {:ok,
       %{
         did: resp["sub"] || session.did,
         pds: session.pds,
         token_endpoint: session.token_endpoint,
         access_token: resp["access_token"],
         refresh_token: resp["refresh_token"],
         scope: resp["scope"],
         expires_at: System.system_time(:second) + (resp["expires_in"] || 600),
         dpop_key: session.dpop_key,
         dpop_nonce: nonce
       }}
    end
  end

  # ── http ──────────────────────────────────────────────────────────────────

  defp post_form(url, form, dpop_proof) do
    Req.post(url, form: form, headers: [{"dpop", dpop_proof}], redirect: false, retry: false)
  end

  defp dpop_nonce(%{headers: headers}) do
    headers
    |> Enum.find_value(fn {k, v} ->
      if String.downcase(k) == "dpop-nonce", do: v
    end)
    |> case do
      [nonce | _] -> nonce
      nonce -> nonce
    end
  end

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
