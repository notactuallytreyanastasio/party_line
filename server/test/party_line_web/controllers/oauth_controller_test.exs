defmodule PartyLineWeb.OAuthControllerTest do
  @moduledoc """
  The atproto OAuth endpoints, minus the two branches that resolve a handle
  over real HTTP (`login` with a handle calls `PartyLine.ATProto.Identity`
  via Req): those stay uncovered here rather than stubbing the network.

  Async false: `PartyLine.ATProto.Sessions` is a globally named GenServer.
  POSTs go through the real :browser pipeline, so each one carries the CSRF
  token scraped from a prior page render.
  """
  use PartyLineWeb.ConnCase, async: false

  alias PartyLine.ATProto.{Client, Sessions}

  # GET any browser page to seed the session with a CSRF token, and hand
  # back both the (sent) conn and the masked token from the meta tag.
  defp csrf(conn) do
    conn = get(conn, ~p"/")
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(conn, 200))
    {conn, token}
  end

  test "the client-metadata document matches Client.metadata/0", %{conn: conn} do
    conn = get(conn, ~p"/oauth/client-metadata.json")
    assert json_response(conn, 200) == Client.metadata()
  end

  test "login without a handle falls through to a redirect home", %{conn: conn} do
    {conn, token} = csrf(conn)
    conn = post(conn, ~p"/oauth/login", %{"_csrf_token" => token})
    assert redirected_to(conn) == ~p"/"
  end

  test "callback with no pending cookie flashes the expiry notice", %{conn: conn} do
    conn = get(conn, ~p"/oauth/callback")
    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "your sign-in expired. try again."
  end

  test "logout without a session cookie still signs out", %{conn: conn} do
    {conn, token} = csrf(conn)
    conn = post(conn, ~p"/oauth/logout", %{"_csrf_token" => token})
    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "signed out"
  end

  test "logout with a live session drops the tokens and the cookie", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    id = Sessions.put_tokens(%{did: "did:plc:oauthtest#{uniq}", access_token: "tok-#{uniq}"})
    assert Sessions.get_tokens(id)

    # sign a pl_session cookie the way the callback would
    secret = PartyLineWeb.Endpoint.config(:secret_key_base)

    cookie =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:secret_key_base, secret)
      |> put_resp_cookie("pl_session", id, sign: true)
      |> Map.fetch!(:resp_cookies)
      |> Map.fetch!("pl_session")
      |> Map.fetch!(:value)

    {conn, token} = csrf(conn)

    conn =
      conn
      |> recycle()
      |> put_req_cookie("pl_session", cookie)
      |> post(~p"/oauth/logout", %{"_csrf_token" => token})

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "signed out"
    assert Sessions.get_tokens(id) == nil
    assert %{max_age: 0} = conn.resp_cookies["pl_session"]
  end
end
