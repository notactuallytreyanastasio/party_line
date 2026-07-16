defmodule PartyLine.ATProto.Client do
  @moduledoc """
  This app's OAuth client identity. atproto uses the *client-metadata
  document URL* as the `client_id` — there is no registration and no
  secret; the auth server fetches the document to learn our redirect URIs
  and scopes.

  In production the client_id is `<base>/oauth/client-metadata.json` served
  publicly over HTTPS. For local dev, atproto defines a special
  loopback client: `client_id` is `http://localhost` with the redirect and
  scope carried as query params, so you can complete the flow without a
  public URL.
  """

  @scope "atproto transition:generic"

  def config do
    base = Application.get_env(:party_line, :atproto)[:base_url] || fallback_base()

    if local_loopback?(base) do
      # RFC 8252 / atproto loopback client: client_id is literally
      # `http://localhost`, but the redirect MUST be the loopback IP
      # 127.0.0.1 (auth servers reject the "localhost" hostname). The
      # redirect_uri and scope ride along as client_id query params.
      redirect_uri = loopback_redirect(base)

      %{
        client_id:
          "http://localhost?" <>
            URI.encode_query(%{"redirect_uri" => redirect_uri, "scope" => @scope}),
        redirect_uri: redirect_uri,
        base_url: base
      }
    else
      %{
        client_id: base <> "/oauth/client-metadata.json",
        redirect_uri: base <> "/oauth/callback",
        base_url: base
      }
    end
  end

  @doc "The client-metadata document (served at the client_id URL in prod)."
  def metadata do
    %{config: %{client_id: client_id, redirect_uri: redirect_uri}} = %{config: config()}

    %{
      "client_id" => client_id,
      "client_name" => "party line",
      "application_type" => "web",
      "dpop_bound_access_tokens" => true,
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "redirect_uris" => [redirect_uri],
      "scope" => @scope,
      "token_endpoint_auth_method" => "none"
    }
  end

  defp local_loopback?(base), do: base =~ ~r{^https?://(localhost|127\.0\.0\.1)}

  defp loopback_redirect(base) do
    base
    |> String.replace("localhost", "127.0.0.1")
    |> Kernel.<>("/oauth/callback")
  end

  defp fallback_base do
    endpoint = PartyLineWeb.Endpoint.url()
    endpoint
  end
end
