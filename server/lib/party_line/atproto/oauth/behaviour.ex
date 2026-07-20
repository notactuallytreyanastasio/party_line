defmodule PartyLine.ATProto.OAuth.Behaviour do
  @moduledoc """
  The OAuth-flow seam the web layer calls, spelled out as a contract so a test
  can substitute a fake instead of reaching the atproto network.

  Two moving parts cross this boundary, and their shapes are the contract:

    * a **session** — the pending-login state minted by `begin/2`, stashed in
      `Sessions` until the callback, and handed back to `finish/2`;
    * **tokens** — what a completed sign-in yields; the web layer reads `:did`
      off it (the signed-in identity) and stores the rest.
  """

  @typedoc "Pending-login state: everything `finish/2` needs to redeem the code."
  @type session :: %{
          required(:state) => String.t(),
          required(:issuer) => String.t(),
          required(:token_endpoint) => String.t(),
          required(:pkce_verifier) => String.t(),
          required(:dpop_key) => term(),
          required(:dpop_nonce) => String.t() | nil,
          required(:did) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "The token bundle a completed sign-in yields."
  @type tokens :: %{
          required(:did) => String.t(),
          required(:access_token) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Begin a flow for a handle or did. On success, returns the authorize URL to
  redirect the user to and the pending `session` to stash.
  """
  @callback begin(handle_or_did :: String.t(), opts :: keyword()) ::
              {:ok, authorize_url :: String.t(), session()} | {:error, term()}

  @doc "Redeem the callback `params` against the pending `session` for tokens."
  @callback finish(session(), params :: map()) :: {:ok, tokens()} | {:error, term()}

  @doc "Trade a refresh token for a fresh pair."
  @callback refresh(tokens(), opts :: keyword()) :: {:ok, tokens()} | {:error, term()}
end
