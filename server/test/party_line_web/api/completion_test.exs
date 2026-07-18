defmodule PartyLineWeb.CompletionTest do
  @moduledoc """
  The public completion API, end to end: atproto-keyed auth, the OpenAI and
  Anthropic shapes, streaming, and the LangChain client dogfooding it over a
  real socket. The exchange is faked (no model), everything else is real.
  """
  use PartyLineWeb.ConnCase, async: false

  alias PartyLine.API.{Client, Keys}
  alias PartyLine.Test.ExchangeFake

  @did "did:plc:testcaller"

  # stands in for the HTTP hop to a lent host — proves the request was proxied
  # with the host's identity, without a real socket
  defmodule FakeHostProxy do
    @behaviour PartyLine.API.HostProxy.Behaviour

    @impl true
    def chat(host, body) do
      [%{"content" => prompt}] = Enum.take(body["messages"], -1)

      {:ok,
       %{
         "object" => "chat.completion",
         "model" => host.model,
         "choices" => [
           %{
             "index" => 0,
             "message" => %{"role" => "assistant", "content" => "proxied<#{prompt}>"},
             "finish_reason" => "stop"
           }
         ]
       }}
    end
  end

  setup do
    %{asks: asks, bots: bots} =
      ExchangeFake.start!(
        [ExchangeFake.card("Horse Dentist", "gemma-4-e4b-8bit")],
        fn prompt -> "answered: #{String.slice(prompt, -20, 20)}" end
      )

    Application.put_env(:party_line, :api_asks, asks)
    Application.put_env(:party_line, :api_bots, bots)

    on_exit(fn ->
      Application.delete_env(:party_line, :api_asks)
      Application.delete_env(:party_line, :api_bots)
    end)

    {:ok, _key, token} = Keys.mint(@did, "test key")
    %{token: token}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp post_json(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  describe "auth" do
    test "no key is a 401 in the OpenAI error shape", %{conn: conn} do
      conn =
        post_json(conn, "/v1/chat/completions", %{messages: [%{role: "user", content: "hi"}]})

      assert conn.status == 401
      assert %{"error" => %{"code" => "invalid_api_key"}} = json_response(conn, 401)
    end

    test "a bad key is a 401", %{conn: conn} do
      conn =
        conn
        |> authed("pl-nonsense")
        |> post_json("/v1/chat/completions", %{messages: [%{role: "user", content: "hi"}]})

      assert conn.status == 401
    end
  end

  describe "GET /v1/models" do
    test "lists party-line-auto and the online persona", %{conn: conn, token: token} do
      body = conn |> authed(token) |> get("/v1/models") |> json_response(200)
      ids = Enum.map(body["data"], & &1["id"])
      assert "party-line-auto" in ids
      assert "Horse Dentist" in ids
      assert body["object"] == "list"
    end
  end

  describe "POST /v1/chat/completions" do
    test "returns the persona's answer as a chat.completion", %{conn: conn, token: token} do
      body =
        conn
        |> authed(token)
        |> post_json("/v1/chat/completions", %{
          model: "party-line-auto",
          messages: [%{role: "user", content: "why do cats knead"}]
        })
        |> json_response(200)

      assert body["object"] == "chat.completion"
      assert [%{"message" => %{"role" => "assistant", "content" => content}}] = body["choices"]
      assert content =~ "answered:"
      assert body["model"] == "Horse Dentist"
      assert body["party_line"]["persona"] == "Horse Dentist"
    end

    test "missing messages is a 400", %{conn: conn, token: token} do
      conn = conn |> authed(token) |> post_json("/v1/chat/completions", %{model: "x"})
      assert conn.status == 400
    end

    test "stream: true returns SSE chunks ending in [DONE]", %{conn: conn, token: token} do
      conn =
        conn
        |> authed(token)
        |> post_json("/v1/chat/completions", %{
          stream: true,
          messages: [%{role: "user", content: "stream me"}]
        })

      assert conn.status == 200

      assert {"content-type", "text/event-stream" <> _} =
               Enum.find(conn.resp_headers, fn {k, _} -> k == "content-type" end)

      assert conn.resp_body =~ "chat.completion.chunk"
      assert conn.resp_body =~ "data: [DONE]"
    end

    test "an empty exchange is a 503", %{conn: conn, token: token} do
      %{asks: empty} = ExchangeFake.start!([])
      Application.put_env(:party_line, :api_asks, empty)

      conn =
        conn
        |> authed(token)
        |> post_json("/v1/chat/completions", %{messages: [%{role: "user", content: "anyone?"}]})

      assert conn.status == 503
    end
  end

  describe "streaming (real relay of a streaming host)" do
    setup %{token: token} do
      %{asks: streaming} =
        ExchangeFake.start!(
          [ExchangeFake.card("Horse Dentist")],
          fn _ -> "hello there friend" end,
          stream: true
        )

      Application.put_env(:party_line, :api_asks, streaming)
      %{token: token}
    end

    test "chat/completions relays the answer as multiple content chunks", %{
      conn: conn,
      token: token
    } do
      conn =
        conn
        |> authed(token)
        |> post_json("/v1/chat/completions", %{
          stream: true,
          messages: [%{role: "user", content: "hi"}]
        })

      assert conn.status == 200
      assert conn.resp_body =~ "data: [DONE]"

      chunks =
        conn.resp_body
        |> String.split("\n\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "data: {"))
        |> Enum.map(&(&1 |> String.replace_prefix("data: ", "") |> Jason.decode!()))

      contents =
        chunks
        |> Enum.flat_map(fn f -> for c <- f["choices"], do: c["delta"]["content"] end)
        |> Enum.reject(&is_nil/1)

      # the whole answer arrives, spread across several real chunks (not one blob)
      assert Enum.join(contents) == "hello there friend"
      assert length(contents) > 1
    end

    test "messages relays content_block_delta events for a streaming host", %{
      conn: conn,
      token: token
    } do
      conn =
        conn
        |> authed(token)
        |> post_json("/v1/messages", %{stream: true, messages: [%{role: "user", content: "hi"}]})

      assert conn.status == 200
      assert conn.resp_body =~ "event: message_start"
      assert conn.resp_body =~ "event: content_block_delta"
      assert conn.resp_body =~ "event: message_stop"

      texts =
        ~r/"text_delta","text":"([^"]*)"/
        |> Regex.scan(conn.resp_body)
        |> Enum.map_join("", &List.last/1)

      assert texts == "hello there friend"
    end
  end

  describe "POST /v1/messages (Anthropic)" do
    test "returns an anthropic message with a text content block", %{conn: conn, token: token} do
      body =
        conn
        |> authed(token)
        |> post_json("/v1/messages", %{
          model: "party-line-auto",
          max_tokens: 100,
          system: "be terse",
          messages: [%{role: "user", content: "why do cats knead"}]
        })
        |> json_response(200)

      assert body["type"] == "message"
      assert body["role"] == "assistant"
      assert [%{"type" => "text", "text" => text}] = body["content"]
      assert text =~ "answered:"
      assert body["stop_reason"] == "end_turn"
    end
  end

  describe "proxying a lent model (exchange-gated)" do
    setup %{token: token} do
      {:ok, hosts} = PartyLine.Hosts.start_link(name: nil)

      {:ok, _} =
        PartyLine.Hosts.register(hosts, %{
          name: "gpu-closet",
          url: "http://gpu-closet.ts.net:8377",
          model: "qwen-7b",
          secret: "sk-host"
        })

      Application.put_env(:party_line, :api_hosts, hosts)
      Application.put_env(:party_line, :api_host_proxy, FakeHostProxy)

      on_exit(fn ->
        Application.delete_env(:party_line, :api_hosts)
        Application.delete_env(:party_line, :api_host_proxy)
      end)

      %{token: token}
    end

    test "a request for a lent model is proxied to its host, attributed", %{
      conn: conn,
      token: token
    } do
      body =
        conn
        |> authed(token)
        |> post_json("/v1/chat/completions", %{
          model: "qwen-7b",
          messages: [%{role: "user", content: "hello host"}]
        })
        |> json_response(200)

      assert body["object"] == "chat.completion"
      assert [%{"message" => %{"content" => "proxied<hello host>"}}] = body["choices"]
      assert body["party_line"]["proxied_via"] == "exchange"
      assert body["party_line"]["host"] == "gpu-closet"
    end

    test "streaming a lent model re-emits the answer as SSE", %{conn: conn, token: token} do
      conn =
        conn
        |> authed(token)
        |> post_json("/v1/chat/completions", %{
          model: "qwen-7b",
          stream: true,
          messages: [%{role: "user", content: "stream host"}]
        })

      assert conn.status == 200
      assert conn.resp_body =~ "data: [DONE]"
      assert conn.resp_body =~ "stream host"
    end

    test "GET /v1/models lists the lent model alongside personas", %{conn: conn, token: token} do
      body = conn |> authed(token) |> get("/v1/models") |> json_response(200)
      lent = Enum.find(body["data"], &(&1["id"] == "qwen-7b"))
      assert lent["owned_by"] == "lent"
      assert lent["party_line"]["host"] == "gpu-closet"
    end

    test "an unknown model still falls through to the persona path", %{conn: conn, token: token} do
      body =
        conn
        |> authed(token)
        |> post_json("/v1/chat/completions", %{
          model: "party-line-auto",
          messages: [%{role: "user", content: "who's home"}]
        })
        |> json_response(200)

      # answered by the fake persona exchange, not the host proxy
      assert body["party_line"]["persona"] == "Horse Dentist"
    end
  end

  describe "the dogfood client (LangChain ChatOpenAI over real HTTP)" do
    test "a real OpenAI client library round-trips against our endpoint", %{token: token} do
      assert {:ok, text} =
               Client.chat("why do cats knead",
                 api_key: token,
                 endpoint: "http://127.0.0.1:4002/v1/chat/completions",
                 model: "party-line-auto"
               )

      assert text =~ "answered:"
    end

    test "the client is rejected without a valid key" do
      assert {:error, _} =
               Client.chat("hi",
                 api_key: "pl-nope",
                 endpoint: "http://127.0.0.1:4002/v1/chat/completions"
               )
    end
  end
end
