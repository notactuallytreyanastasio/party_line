defmodule PartyLine.ATProto.Identity do
  @moduledoc """
  Resolve an atproto identity to what OAuth needs: handle → DID → PDS →
  authorization server.

  - A handle (`alice.bsky.social`) resolves to a DID via DNS TXT or the
    `/.well-known/atproto-did` HTTP method; here we use the HTTP method,
    which every PDS serves.
  - A DID (`did:plc:…` / `did:web:…`) resolves to a DID document; its
    `service` entry of type `AtprotoPersonalDataServer` gives the PDS URL.
  - The PDS's `/.well-known/oauth-protected-resource` names the
    authorization server, whose metadata carries the PAR/token endpoints.
  """

  # Network bases, configurable with prod defaults so tests can point the whole
  # resolve chain at a stub (the PDS + auth-server come from response bodies, so
  # a stub controls those by what it returns).
  defp plc, do: Application.get_env(:party_line, :atproto_plc, "https://plc.directory")

  defp resolver,
    do: Application.get_env(:party_line, :atproto_resolver, "https://public.api.bsky.app")

  @doc "handle-or-did → %{did, handle, pds, auth_server}"
  def resolve(input) do
    input = String.trim(input)

    with {:ok, did, handle} <- to_did(input),
         {:ok, pds} <- pds_for(did),
         {:ok, auth_server} <- auth_server_for(pds) do
      {:ok, %{did: did, handle: handle, pds: pds, auth_server: auth_server}}
    end
  end

  @doc "Fetch an authorization server's OAuth metadata document."
  def auth_server_metadata(auth_server) do
    get_json("#{auth_server}/.well-known/oauth-authorization-server")
  end

  # ── steps ─────────────────────────────────────────────────────────────────

  defp to_did("did:" <> _ = did), do: {:ok, did, nil}

  defp to_did(handle) do
    host = handle |> String.trim_leading("@")

    # canonical resolver first (covers DNS-TXT handles like *.bsky.social),
    # then the HTTP well-known method as a fallback for self-hosted handles
    with :error <- resolve_via_xrpc(host),
         :error <- resolve_via_wellknown(host) do
      {:error, :handle_unresolved}
    else
      {:ok, did} -> {:ok, did, host}
    end
  end

  defp resolve_via_xrpc(host) do
    case get_json("#{resolver()}/xrpc/com.atproto.identity.resolveHandle?handle=#{host}") do
      {:ok, %{"did" => "did:" <> _ = did}} -> {:ok, did}
      _ -> :error
    end
  end

  defp resolve_via_wellknown(host) do
    case get("https://#{host}/.well-known/atproto-did") do
      {:ok, body} ->
        did = String.trim(body)
        if String.starts_with?(did, "did:"), do: {:ok, did}, else: :error

      _ ->
        :error
    end
  end

  defp pds_for("did:plc:" <> _ = did) do
    with {:ok, doc} <- get_json("#{plc()}/#{did}") do
      extract_pds(doc)
    end
  end

  defp pds_for("did:web:" <> host = _did) do
    with {:ok, doc} <- get_json("https://#{host}/.well-known/did.json") do
      extract_pds(doc)
    end
  end

  defp pds_for(_), do: {:error, :unsupported_did}

  defp extract_pds(%{"service" => services}) when is_list(services) do
    services
    |> Enum.find(&(&1["type"] == "AtprotoPersonalDataServer"))
    |> case do
      %{"serviceEndpoint" => endpoint} -> {:ok, endpoint}
      _ -> {:error, :no_pds}
    end
  end

  defp extract_pds(_), do: {:error, :no_pds}

  defp auth_server_for(pds) do
    case get_json("#{pds}/.well-known/oauth-protected-resource") do
      {:ok, %{"authorization_servers" => [server | _]}} -> {:ok, server}
      {:ok, _} -> {:error, :no_auth_server}
      {:error, _} = err -> err
    end
  end

  # ── http ──────────────────────────────────────────────────────────────────

  defp get_json(url) do
    with {:ok, body} <- get(url) do
      case Jason.decode(body) do
        {:ok, json} -> {:ok, json}
        _ -> {:error, :bad_json}
      end
    end
  end

  defp get(url) do
    case Req.get(url, redirect: true, retry: false, max_retries: 0) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} -> {:ok, Jason.encode!(body)}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
