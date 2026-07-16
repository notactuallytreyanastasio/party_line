defmodule PartyLineWeb.HostControllerTest do
  # Drives the app-started catalog through the real HTTP stack, so it is
  # serialized (async: false) and cleans up whatever it registers.
  use PartyLineWeb.ConnCase, async: false

  @valid %{
    "name" => "gpu-closet",
    "url" => "http://gpu-closet.tailnet.ts.net:8080",
    "model" => "qwen2.5-coder-7b",
    "requires_token" => true
  }

  setup do
    on_exit(fn -> Enum.each(PartyLine.Hosts.list(), &PartyLine.Hosts.deregister(&1.id)) end)
    :ok
  end

  defp register!(conn, attrs \\ @valid) do
    conn = post(conn, ~p"/api/hosts/register", attrs)

    assert %{"ok" => true, "data" => %{"id" => id, "ttl_seconds" => ttl}} =
             json_response(conn, 201)

    {id, ttl}
  end

  test "register returns 201 with the id/ttl envelope", %{conn: conn} do
    {id, ttl} = register!(conn)
    assert id =~ ~r/\A[0-9a-f]{16}\z/
    assert is_integer(ttl) and ttl > 0
  end

  test "register rejects a bad url with 422", %{conn: conn} do
    conn = post(conn, ~p"/api/hosts/register", %{@valid | "url" => "ftp://nope"})
    assert %{"ok" => false, "error" => error} = json_response(conn, 422)
    assert error =~ "url"
  end

  test "index lists cataloged hosts without leaking the id", %{conn: conn} do
    register!(conn)

    conn = get(conn, ~p"/api/hosts")
    assert %{"ok" => true, "data" => %{"hosts" => [host]}} = json_response(conn, 200)

    assert host["name"] == "gpu-closet"
    assert host["url"] == @valid["url"]
    assert host["model"] == "qwen2.5-coder-7b"
    assert host["requires_token"] == true
    assert is_binary(host["last_seen_at"])
    refute Map.has_key?(host, "id")
  end

  test "heartbeat returns 200 for a known host", %{conn: conn} do
    {id, _ttl} = register!(conn)

    conn = post(conn, ~p"/api/hosts/#{id}/heartbeat")
    assert %{"ok" => true, "data" => %{"id" => ^id}} = json_response(conn, 200)
  end

  test "heartbeat returns 404 for an unknown host", %{conn: conn} do
    conn = post(conn, ~p"/api/hosts/deadbeefdeadbeef/heartbeat")
    assert %{"ok" => false, "error" => _} = json_response(conn, 404)
  end

  test "deregister returns 204 and drops the host", %{conn: conn} do
    {id, _ttl} = register!(conn)

    conn = delete(conn, ~p"/api/hosts/#{id}")
    assert response(conn, 204) == ""

    conn = get(build_conn(), ~p"/api/hosts")
    assert %{"data" => %{"hosts" => []}} = json_response(conn, 200)
  end
end
