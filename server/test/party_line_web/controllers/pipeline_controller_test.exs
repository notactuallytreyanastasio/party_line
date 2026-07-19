defmodule PartyLineWeb.PipelineControllerTest do
  # Drives the app-started shard catalog through the real HTTP stack, so it is
  # serialized (async: false) and clears whatever it registers.
  use PartyLineWeb.ConnCase, async: false

  alias PartyLine.API.Keys

  @shard %{
    "model" => "big-model-70b",
    "index" => 0,
    "count" => 2,
    "url" => "http://shard-a.tailnet.ts.net:8378",
    "secret" => "sk-shard-a"
  }

  setup do
    on_exit(fn -> PartyLine.Pipelines.clear() end)
    {:ok, _key, token} = Keys.mint("did:plc:owner", "serve-shard")
    %{token: token}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  test "registration requires an atproto-bound key", %{conn: conn} do
    conn = post(conn, ~p"/api/pipelines/register", @shard)
    assert conn.status == 401
  end

  test "register returns 201 with the id/ttl envelope", %{conn: conn, token: token} do
    conn = conn |> authed(token) |> post(~p"/api/pipelines/register", @shard)

    assert %{"ok" => true, "data" => %{"id" => id, "ttl_seconds" => ttl}} = json_response(conn, 201)
    assert id =~ ~r/\A[0-9a-f]{16}\z/
    assert is_integer(ttl) and ttl > 0
  end

  test "register rejects an out-of-range stage with 422", %{conn: conn, token: token} do
    conn = conn |> authed(token) |> post(~p"/api/pipelines/register", %{@shard | "index" => 5})
    assert %{"ok" => false, "error" => "invalid_stage"} = json_response(conn, 422)
  end

  test "index assembles pipelines and never leaks addresses", %{conn: conn, token: token} do
    {:ok, _key, other} = Keys.mint("did:plc:bob", "serve-shard")
    conn |> authed(token) |> post(~p"/api/pipelines/register", @shard)
    conn |> authed(other) |> post(~p"/api/pipelines/register", %{@shard | "index" => 1, "secret" => "sk-b"})

    conn = get(build_conn(), ~p"/api/pipelines")
    assert %{"ok" => true, "data" => %{"pipelines" => [p]}} = json_response(conn, 200)
    assert p["model"] == "big-model-70b" and p["count"] == 2 and p["ready"] == true
    refute Map.has_key?(p, "url")
    refute Map.has_key?(p, "secret")
  end

  test "lease hands the driver the ordered endpoints + secrets", %{conn: conn, token: token} do
    conn |> authed(token) |> post(~p"/api/pipelines/register", @shard)

    conn
    |> authed(token)
    |> post(~p"/api/pipelines/register", %{
      @shard
      | "index" => 1,
        "url" => "http://shard-b.ts.net:8378",
        "secret" => "sk-shard-b"
    })

    conn =
      conn |> authed(token) |> post(~p"/api/pipelines/lease", %{"model" => "big-model-70b"})

    assert %{"ok" => true, "data" => %{"stages" => stages}} = json_response(conn, 200)
    assert [%{"index" => 0, "url" => u0, "secret" => "sk-shard-a"}, %{"index" => 1, "secret" => "sk-shard-b"}] = stages
    assert u0 == "http://shard-a.tailnet.ts.net:8378"
  end

  test "lease requires auth and 404s an incomplete pipeline", %{conn: conn, token: token} do
    # unauthenticated
    assert post(conn, ~p"/api/pipelines/lease", %{"model" => "big-model-70b"}).status == 401

    # only one stage present → not assemblable
    conn |> authed(token) |> post(~p"/api/pipelines/register", @shard)
    out = conn |> authed(token) |> post(~p"/api/pipelines/lease", %{"model" => "big-model-70b"})
    assert %{"ok" => false} = json_response(out, 404)
  end

  test "heartbeat and deregister are owner-bound", %{conn: conn, token: token} do
    conn2 = conn |> authed(token) |> post(~p"/api/pipelines/register", @shard)
    %{"data" => %{"id" => id}} = json_response(conn2, 201)

    {:ok, _key, other} = Keys.mint("did:plc:mallory", "attacker")
    assert conn |> authed(other) |> post(~p"/api/pipelines/#{id}/heartbeat") |> json_response(403)

    assert conn |> authed(token) |> post(~p"/api/pipelines/#{id}/heartbeat") |> json_response(200)
    assert response(conn |> authed(token) |> delete(~p"/api/pipelines/#{id}"), 204) == ""
  end
end
