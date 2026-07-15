defmodule PartyLineWeb.BotSocketTest do
  @moduledoc """
  Drives the real Bandit server over real WebSockets — verifies the wire
  contract a Python harness will rely on, not just the GenServer API.
  """
  use ExUnit.Case, async: false

  defmodule WS do
    @moduledoc "Minimal blocking WebSocket client over Mint.WebSocket."

    defstruct [:conn, :ref, :websocket, buffer: []]

    def connect!(path) do
      {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", 4002)
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, [])

      socket = Mint.HTTP.get_socket(conn)

      {conn, websocket} =
        receive do
          {:tcp, ^socket, _} = message ->
            {:ok, conn, [{:status, ^ref, 101} | _] = responses} =
              Mint.WebSocket.stream(conn, message)

            headers = for {:headers, ^ref, h} <- responses, do: h
            {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, hd(headers))
            {conn, websocket}
        after
          2_000 -> raise "upgrade timed out"
        end

      %__MODULE__{conn: conn, ref: ref, websocket: websocket}
    end

    def send!(ws, payload) do
      {:ok, websocket, data} = Mint.WebSocket.encode(ws.websocket, {:text, Jason.encode!(payload)})
      {:ok, conn} = Mint.WebSocket.stream_request_body(ws.conn, ws.ref, data)
      %{ws | conn: conn, websocket: websocket}
    end

    @doc "Receive the next JSON frame matching `pred`, buffering the rest."
    def recv!(ws, pred, timeout \\ 2_000) do
      case Enum.split_with(ws.buffer, pred) do
        {[match | rest_matching], rest} ->
          {match, %{ws | buffer: rest ++ rest_matching}}

        {[], _} ->
          deadline = System.monotonic_time(:millisecond) + timeout
          recv_loop(ws, pred, deadline)
      end
    end

    defp recv_loop(ws, pred, deadline) do
      remaining = deadline - System.monotonic_time(:millisecond)
      if remaining <= 0, do: raise("timed out waiting for frame; buffer: #{inspect(ws.buffer)}")

      # several conns share the test process mailbox: receive only this
      # conn's socket messages, leave the others queued
      socket = Mint.HTTP.get_socket(ws.conn)

      receive do
        {:tcp, ^socket, _} = message ->
          handle_stream(ws, pred, deadline, message)

        {:tcp_closed, ^socket} = message ->
          handle_stream(ws, pred, deadline, message)

        {:tcp_error, ^socket, _} = message ->
          handle_stream(ws, pred, deadline, message)
      after
        remaining -> raise "timed out waiting for frame; buffer: #{inspect(ws.buffer)}"
      end
    end

    defp handle_stream(ws, pred, deadline, message) do
      case Mint.WebSocket.stream(ws.conn, message) do
            {:ok, conn, responses} ->
              frames =
                for {:data, ref, data} <- responses, ref == ws.ref do
                  {:ok, _websocket, frames} = Mint.WebSocket.decode(ws.websocket, data)
                  frames
                end

              decoded =
                frames
                |> List.flatten()
                |> Enum.flat_map(fn
                  {:text, text} -> [Jason.decode!(text)]
                  _ -> []
                end)

              ws = %{ws | conn: conn, buffer: ws.buffer ++ decoded}

              case Enum.find(ws.buffer, pred) do
                nil -> recv_loop(ws, pred, deadline)
                match -> {match, %{ws | buffer: List.delete(ws.buffer, match)}}
              end

        {:error, _conn, reason, _} ->
          raise "websocket error: #{inspect(reason)}"
      end
    end
  end

  defp type(t), do: fn frame -> frame["type"] == t end

  defp fresh_room do
    id = "room-sock-#{System.unique_integer([:positive])}"
    {:ok, _} = PartyLine.Rooms.ensure_room(id, topic: "socket test topic")
    id
  end

  defp join!(name, kind, room_id, extra \\ %{}) do
    ws = WS.connect!("/ws/bot/websocket")

    ws =
      WS.send!(
        ws,
        Map.merge(%{type: "join", name: name, kind: kind, room_id: room_id}, extra)
      )

    {welcome, ws} = WS.recv!(ws, type("welcome"))
    {welcome, ws}
  end

  test "dial endpoint returns the default room" do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:4002/api/dial", [], ~c"application/json", ~c"{}"},
        [],
        []
      )

    assert %{"room_id" => "room-default", "ws_url" => "/ws/bot/websocket"} =
             Jason.decode!(body)
  end

  test "full bot round-trip: join → beat → bid → grant → speak → message" do
    room_id = fresh_room()
    {welcome, ws} = join!("Nova", "bot", room_id)

    assert welcome["room"]["topic"] == "socket test topic"
    assert [%{"name" => "Nova", "kind" => "bot"}] = welcome["roster"]

    {beat, ws} = WS.recv!(ws, type("beat"))
    ws = WS.send!(ws, %{type: "bid", beat_id: beat["beat_id"], urge: 0.9})

    {grant, ws} = WS.recv!(ws, type("grant"))
    ws = WS.send!(ws, %{type: "speak", grant_id: grant["grant_id"], body: "hello line"})

    {message, _ws} = WS.recv!(ws, type("message"))
    assert message["body"] == "hello line"
    assert message["sender"]["name"] == "Nova"
    assert message["seq"] == 1
  end

  test "mentions are parsed server-side and delivered structured" do
    room_id = fresh_room()
    {_w, bot} = join!("Nova", "bot", room_id)
    {w, human} = join!("Bobby", "human", room_id)
    assert w["participant_id"]

    _human = WS.send!(human, %{type: "speak", body: "@nova you up?"})

    {message, _} = WS.recv!(bot, type("message"))
    assert [%{"name" => "Nova", "kind" => "bot"}] = message["mentions"]
  end

  test "lurking human is invisible until announce" do
    room_id = fresh_room()
    {_w, bot} = join!("Nova", "bot", room_id)
    {w, lurker} = join!("Ghost", "human", room_id, %{lurk: true})
    # the lurker sees the roster but is not in it
    assert Enum.map(w["roster"], & &1["name"]) == ["Nova"]

    _lurker = WS.send!(lurker, %{type: "announce"})
    {presence, _} = WS.recv!(bot, type("presence"))
    assert presence["event"] == "announced"
    assert presence["participant"]["name"] == "Ghost"
  end

  test "speaking without join is rejected" do
    ws = WS.connect!("/ws/bot/websocket")
    ws = WS.send!(ws, %{type: "speak", body: "hi"})
    {error, _} = WS.recv!(ws, type("error"))
    assert error["code"] == "not_joined"
  end
end
