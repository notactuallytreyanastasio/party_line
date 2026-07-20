defmodule PartyLineWeb.OAuthController do
  @moduledoc """
  atproto OAuth endpoints: the client-metadata document, the login kickoff,
  and the callback. Sign in with your handle — no app passwords.
  """
  use PartyLineWeb, :controller

  alias PartyLine.ATProto.{Client, OAuth, Sessions}

  @cookie "pl_oauth"

  @doc "The client-metadata document the auth server fetches (prod client_id)."
  def client_metadata(conn, _params) do
    json(conn, Client.metadata())
  end

  @doc "POST /oauth/login — kick off the flow for a handle."
  def login(conn, %{"handle" => handle}) do
    case oauth_flow().begin(handle, client: Client.config()) do
      {:ok, url, session} ->
        pending_id = Sessions.put_pending(session)

        conn
        |> put_resp_cookie(@cookie, pending_id, sign: true, max_age: 600, same_site: "Lax")
        |> redirect(external: url)

      {:error, reason} ->
        conn
        |> put_flash(:error, "couldn't reach that handle's server: #{inspect(reason)}")
        |> redirect(to: ~p"/")
    end
  end

  def login(conn, _), do: redirect(conn, to: ~p"/")

  @doc "GET /oauth/callback — exchange the code for tokens."
  def callback(conn, params) do
    conn = fetch_cookies(conn, signed: [@cookie])

    with pending_id when is_binary(pending_id) <- conn.cookies[@cookie],
         session when is_map(session) <- Sessions.take_pending(pending_id),
         {:ok, tokens} <- oauth_flow().finish(session, Map.put(params, :client, Client.config())) do
      session_id = Sessions.put_tokens(tokens)

      conn
      |> delete_resp_cookie(@cookie)
      |> put_resp_cookie("pl_session", session_id, sign: true, max_age: 86_400, same_site: "Lax")
      |> put_flash(:info, "signed in as #{tokens.did}")
      |> redirect(to: ~p"/")
    else
      nil ->
        conn |> put_flash(:error, "your sign-in expired. try again.") |> redirect(to: ~p"/")

      {:error, reason} ->
        conn
        |> put_flash(:error, "sign-in failed: #{inspect(reason)}")
        |> redirect(to: ~p"/")
    end
  end

  @doc "Sign out — drop the session."
  def logout(conn, _params) do
    conn = fetch_cookies(conn, signed: ["pl_session"])
    if id = conn.cookies["pl_session"], do: Sessions.delete_tokens(id)

    conn
    |> delete_resp_cookie("pl_session")
    |> put_flash(:info, "signed out")
    |> redirect(to: ~p"/")
  end

  # The OAuth flow is a seam (PartyLine.ATProto.OAuth.Behaviour): the real
  # implementation reaches the atproto network, so tests substitute a fake to
  # exercise the controller's branches without it.
  defp oauth_flow, do: Application.get_env(:party_line, :oauth_flow, OAuth)
end
