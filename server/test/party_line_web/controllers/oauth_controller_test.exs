defmodule PartyLineWeb.OAuthControllerTest do
  @moduledoc """
  The atproto OAuth endpoints. The `login`/`callback` flow crosses the OAuth
  seam (`PartyLine.ATProto.OAuth.Behaviour`) — the real implementation reaches
  the atproto network, so we substitute `FakeOAuth` via the `:oauth_flow` config
  to drive the controller's branches (redirect + cookie on begin, tokens +
  session cookie on finish, and both error paths) without a network.

  Async false: `PartyLine.ATProto.Sessions` is a globally named GenServer, and
  the `:oauth_flow` env is process-global. POSTs go through the real :browser
  pipeline, so each carries the CSRF token scraped from a prior page render.
  """
  use PartyLineWeb.ConnCase, async: false

  alias PartyLine.ATProto.{Client, Sessions}

  # The fake at the OAuth boundary. Its return shapes ARE the contract the
  # controller depends on (see the behaviour); it branches on the input so one
  # module serves every case.
  defmodule FakeOAuth do
    @behaviour PartyLine.ATProto.OAuth.Behaviour

    @session %{
      state: "state-1",
      issuer: "https://pds.example",
      token_endpoint: "https://pds.example/token",
      pkce_verifier: "verifier-1",
      dpop_key: :fake_key,
      dpop_nonce: nil,
      did: "did:plc:signedin"
    }

    def pending_session, do: @session

    @impl true
    def begin("bad.handle", _opts), do: {:error, :handle_unresolved}
    def begin(_handle, _opts), do: {:ok, "https://pds.example/authorize?request_uri=urn:x", @session}

    @impl true
    def finish(_session, %{"code" => "bad-code"}), do: {:error, :state_mismatch}
    def finish(_session, _params), do: {:ok, %{did: "did:plc:signedin", access_token: "at-1"}}

    @impl true
    def refresh(_tokens, _opts), do: {:ok, %{did: "did:plc:signedin", access_token: "at-2"}}
  end

  setup do
    Application.put_env(:party_line, :oauth_flow, FakeOAuth)
    on_exit(fn -> Application.delete_env(:party_line, :oauth_flow) end)
    :ok
  end

  # sign a value the way the controller signs its cookies, for a request cookie
  defp signed_cookie(name, value) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:secret_key_base, PartyLineWeb.Endpoint.config(:secret_key_base))
    |> put_resp_cookie(name, value, sign: true)
    |> Map.fetch!(:resp_cookies)
    |> Map.fetch!(name)
    |> Map.fetch!(:value)
  end

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

  test "login with a handle begins the flow: redirect out + a signed pending cookie", %{conn: conn} do
    {conn, token} = csrf(conn)
    conn = post(conn, ~p"/oauth/login", %{"_csrf_token" => token, "handle" => "alice.test"})

    # sent to the authorize URL the flow returned
    assert redirected_to(conn, 302) == "https://pds.example/authorize?request_uri=urn:x"
    # with a pending cookie that outlives the round-trip (10 min), signed
    assert %{max_age: 600, value: value} = conn.resp_cookies["pl_oauth"]
    assert is_binary(value) and value != ""
  end

  test "login flashes when the handle can't be resolved", %{conn: conn} do
    {conn, token} = csrf(conn)
    conn = post(conn, ~p"/oauth/login", %{"_csrf_token" => token, "handle" => "bad.handle"})

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "couldn't reach that handle's server"
    refute conn.resp_cookies["pl_oauth"]
  end

  test "callback exchanges the code: session cookie set, pending cookie dropped", %{conn: conn} do
    pending_id = Sessions.put_pending(FakeOAuth.pending_session())

    conn =
      conn
      |> put_req_cookie("pl_oauth", signed_cookie("pl_oauth", pending_id))
      |> get(~p"/oauth/callback?state=state-1&iss=https://pds.example&code=good-code")

    assert redirected_to(conn) == ~p"/"
    # the flash carries tokens.did — proof the exchanged tokens flowed through
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "signed in as did:plc:signedin"
    # a live session cookie is minted (signed), and the one-shot pending cookie cleared
    assert %{max_age: 86_400, value: sid} = conn.resp_cookies["pl_session"]
    assert is_binary(sid) and sid != ""
    assert %{max_age: 0} = conn.resp_cookies["pl_oauth"]
    # the pending session was consumed (single-use)
    assert Sessions.take_pending(pending_id) == nil
  end

  test "callback flashes on a failed exchange", %{conn: conn} do
    pending_id = Sessions.put_pending(FakeOAuth.pending_session())

    conn =
      conn
      |> put_req_cookie("pl_oauth", signed_cookie("pl_oauth", pending_id))
      |> get(~p"/oauth/callback?state=state-1&code=bad-code")

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "sign-in failed"
    refute conn.resp_cookies["pl_session"]
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
