defmodule PartyLineWeb.HostControllerTest do
  # Drives the app-started catalog through the real HTTP stack, so it is
  # serialized (async: false) and cleans up whatever it registers.
  use PartyLineWeb.ConnCase, async: false

  alias PartyLine.API.Keys

  @valid %{
    "name" => "gpu-closet",
    "url" => "http://gpu-closet.tailnet.ts.net:8080",
    "model" => "qwen2.5-coder-7b",
    "secret" => "sk-host"
  }

  setup do
    # the public list no longer carries the catalog id (you can't deregister a
    # stranger's host), so clear the whole catalog between tests instead
    on_exit(fn -> PartyLine.Hosts.clear() end)
    {:ok, _key, token} = Keys.mint("did:plc:owner", "serve-llm")
    %{token: token}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp register!(conn, token, attrs \\ @valid) do
    conn = conn |> authed(token) |> post(~p"/api/hosts/register", attrs)

    assert %{"ok" => true, "data" => %{"id" => id, "ttl_seconds" => ttl}} =
             json_response(conn, 201)

    {id, ttl}
  end

  test "registration requires an atproto-bound key", %{conn: conn} do
    conn = post(conn, ~p"/api/hosts/register", @valid)
    assert conn.status == 401
  end

  test "register returns 201 with the id/ttl envelope", %{conn: conn, token: token} do
    {id, ttl} = register!(conn, token)
    assert id =~ ~r/\A[0-9a-f]{16}\z/
    assert is_integer(ttl) and ttl > 0
  end

  test "register rejects a bad url with 422", %{conn: conn, token: token} do
    conn =
      conn |> authed(token) |> post(~p"/api/hosts/register", %{@valid | "url" => "ftp://nope"})

    assert %{"ok" => false, "error" => error} = json_response(conn, 422)
    assert error =~ "url"
  end

  test "register rejects a reserved model name with 422", %{conn: conn, token: token} do
    conn =
      conn
      |> authed(token)
      |> post(~p"/api/hosts/register", %{@valid | "model" => "party-line-auto"})

    assert %{"ok" => false, "error" => "reserved_name"} = json_response(conn, 422)
  end

  test "index lists cataloged hosts without leaking url, secret, or id", %{
    conn: conn,
    token: token
  } do
    register!(conn, token)

    # index is a public read — no auth needed
    conn = get(build_conn(), ~p"/api/hosts")
    assert %{"ok" => true, "data" => %{"hosts" => [host]}} = json_response(conn, 200)

    assert host["name"] == "gpu-closet"
    assert host["model"] == "qwen2.5-coder-7b"
    assert is_binary(host["last_seen_at"])

    # a lent model is reached through the exchange, so none of this leaks
    refute Map.has_key?(host, "url")
    refute Map.has_key?(host, "secret")
    refute Map.has_key?(host, "id")
  end

  test "heartbeat returns 200 for the owner", %{conn: conn, token: token} do
    {id, _ttl} = register!(conn, token)

    conn = conn |> authed(token) |> post(~p"/api/hosts/#{id}/heartbeat")
    assert %{"ok" => true, "data" => %{"id" => ^id}} = json_response(conn, 200)
  end

  test "a different identity can't heartbeat someone else's host (403)", %{
    conn: conn,
    token: token
  } do
    {id, _ttl} = register!(conn, token)
    {:ok, _k, other} = Keys.mint("did:plc:mallory", "attacker")

    conn = conn |> authed(other) |> post(~p"/api/hosts/#{id}/heartbeat")
    assert %{"ok" => false} = json_response(conn, 403)
  end

  test "heartbeat returns 404 for an unknown host", %{conn: conn, token: token} do
    conn = conn |> authed(token) |> post(~p"/api/hosts/deadbeefdeadbeef/heartbeat")
    assert %{"ok" => false, "error" => _} = json_response(conn, 404)
  end

  test "deregister returns 204 and drops the host", %{conn: conn, token: token} do
    {id, _ttl} = register!(conn, token)

    conn = conn |> authed(token) |> delete(~p"/api/hosts/#{id}")
    assert response(conn, 204) == ""

    conn = get(build_conn(), ~p"/api/hosts")
    assert %{"data" => %{"hosts" => []}} = json_response(conn, 200)
  end
end
