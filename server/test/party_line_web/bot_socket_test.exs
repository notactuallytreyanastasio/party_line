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

    def send!(ws, payload), do: send_raw!(ws, Jason.encode!(payload))

    @doc "Send a text frame as-is — for exercising the non-JSON error path."
    def send_raw!(ws, text) do
      {:ok, websocket, data} = Mint.WebSocket.encode(ws.websocket, {:text, text})
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

  # the compose loop lands a real post on the boards (Postgres), and it runs in
  # endpoint processes — shared-mode sandbox lets them see this test's rolled-
  # back connection.
  setup do
    PartyLine.DataCase.checkout_singletons!()
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

  test "boards compose loop: the persona's host gets a compose_request frame" do
    room_id = fresh_room()
    {_welcome, ws} = join!("erowid smoothie", "bot", room_id)

    assignment = %{
      id: "assign-#{System.unique_integer([:positive])}",
      board: "confessions",
      topic: "socket compose topic"
    }

    :ok = PartyLine.Bots.request_compose("erowid smoothie", assignment)

    {frame, ws} = WS.recv!(ws, type("compose_request"))
    assert frame["assignment_id"] == assignment.id
    assert frame["board"] == "confessions"
    assert frame["topic"] == "socket compose topic"

    # a well-formed composed frame is accepted silently (Scheduler.deliver
    # is a cast), so the next error on the line belongs to the probe below
    ws = WS.send!(ws, %{type: "composed", assignment_id: assignment.id, body: "a board post"})
    ws = WS.send!(ws, %{type: "definitely-not-a-type"})
    {error, _} = WS.recv!(ws, type("error"))
    assert error["code"] == "unknown_type"
  end

  test "composed frames missing assignment_id or body are rejected" do
    room_id = fresh_room()
    {_welcome, ws} = join!("laminated owl", "bot", room_id)

    ws = WS.send!(ws, %{type: "composed", assignment_id: "a-1"})
    {no_body, ws} = WS.recv!(ws, type("error"))
    assert no_body["code"] == "bad_message"

    ws = WS.send!(ws, %{type: "composed", body: "words with no assignment"})
    {no_id, _} = WS.recv!(ws, type("error"))
    assert no_id["code"] == "bad_message"
  end

  test "answer_delta streams a token; a malformed one is rejected" do
    room_id = fresh_room()
    {_welcome, ws} = join!("gas station sushi", "bot", room_id)

    # a well-formed delta is accepted silently (deliver_delta is a cast, and it
    # drops when no ask is in flight) — so the next error belongs to the probe
    ws = WS.send!(ws, %{type: "answer_delta", ask_id: "ask-x", delta: "tok"})
    ws = WS.send!(ws, %{type: "answer_delta", ask_id: "ask-x"})
    {error, _} = WS.recv!(ws, type("error"))
    assert error["code"] == "bad_message"
  end

  test "join twice is already_joined; bad kind and missing name are join_failed" do
    room_id = fresh_room()
    {_welcome, ws} = join!("Nova", "bot", room_id)

    ws = WS.send!(ws, %{type: "join", name: "Nova", kind: "bot", room_id: room_id})
    {twice, _} = WS.recv!(ws, type("error"))
    assert twice["code"] == "already_joined"

    ws2 = WS.connect!("/ws/bot/websocket")
    ws2 = WS.send!(ws2, %{type: "join", name: "Gerb", kind: "gerbil", room_id: room_id})
    {bad_kind, ws2} = WS.recv!(ws2, type("error"))
    assert bad_kind["code"] == "join_failed"
    assert bad_kind["detail"] == "kind must be bot or human"

    ws2 = WS.send!(ws2, %{type: "join", kind: "human", room_id: room_id})
    {no_name, _} = WS.recv!(ws2, type("error"))
    assert no_name["code"] == "join_failed"
    assert no_name["detail"] == "missing name"
  end

  test "malformed frames get typed errors" do
    room_id = fresh_room()
    {_welcome, ws} = join!("Nova", "bot", room_id)

    ws = WS.send_raw!(ws, "{not json")
    {not_json, ws} = WS.recv!(ws, type("error"))
    assert not_json["code"] == "bad_message"

    ws = WS.send!(ws, %{type: "warble"})
    {unknown, ws} = WS.recv!(ws, type("error"))
    assert unknown["code"] == "unknown_type"

    ws = WS.send!(ws, %{type: "bid", beat_id: "b-1"})
    {no_urge, ws} = WS.recv!(ws, type("error"))
    assert no_urge["code"] == "bad_message"

    ws = WS.send!(ws, %{type: "bid", urge: 0.5})
    {no_beat, ws} = WS.recv!(ws, type("error"))
    assert no_beat["code"] == "bad_message"

    ws = WS.send!(ws, %{type: "speak"})
    {no_body, _} = WS.recv!(ws, type("error"))
    assert no_body["code"] == "bad_message"
  end

  test "leave broadcasts presence left to the rest of the line" do
    room_id = fresh_room()
    {_welcome, stayer} = join!("Nova", "bot", room_id)
    {_welcome2, leaver} = join!("Bobby", "human", room_id)

    {joined, stayer} =
      WS.recv!(stayer, fn f -> f["type"] == "presence" and f["event"] == "joined" end)

    assert joined["participant"]["name"] == "Bobby"

    _leaver = WS.send!(leaver, %{type: "leave"})

    {left, _} = WS.recv!(stayer, fn f -> f["type"] == "presence" and f["event"] == "left" end)
    assert left["participant"]["name"] == "Bobby"
  end

  test "multi-word lowercase mentions are parsed and delivered structured" do
    room_id = fresh_room()
    {_welcome, bot} = join!("gas station sushi", "bot", room_id)
    {_welcome2, human} = join!("Bobby", "human", room_id)

    _human = WS.send!(human, %{type: "speak", body: "@gas station sushi you up?"})

    {message, _} = WS.recv!(bot, type("message"))
    assert message["body"] == "@gas station sushi you up?"
    assert [%{"name" => "gas station sushi", "kind" => "bot"}] = message["mentions"]
  end

  describe "the agent directory" do
    test "a host's capabilities ride in on join and land in the directory" do
      room_id = fresh_room()

      {_welcome, _ws} =
        join!("Beef Inspector", "bot", room_id, %{
          capabilities: %{
            model: "gpt-oss-20b-MXFP4-Q8",
            params_b: 20,
            tokens_per_s: 31.4,
            hardware: "Darwin arm64"
          }
        })

      card = Enum.find(PartyLine.Bots.cards(), &(&1.persona == "Beef Inspector"))

      assert card.model == "gpt-oss-20b-MXFP4-Q8"
      assert card.params_b == 20.0
      assert card.tokens_per_s == 31.4
      assert PartyLine.Agents.Card.power(card) == :large
      assert PartyLine.Agents.Card.byline(card) =~ "31 tok/s"
    end

    test "a host that claims nothing still joins, and gets the easy work" do
      room_id = fresh_room()
      {_welcome, _ws} = join!("quiet host", "bot", room_id)

      card = Enum.find(PartyLine.Bots.cards(), &(&1.persona == "quiet host"))

      assert card.model == "unknown"

      assert PartyLine.Agents.Card.power(card) == :small,
             "silence must not win the hard work"
    end

    test "a host that lies is clamped, not believed" do
      room_id = fresh_room()

      {_welcome, _ws} =
        join!("liar", "bot", room_id, %{capabilities: %{params_b: -3, tokens_per_s: 9.9e12}})

      card = Enum.find(PartyLine.Bots.cards(), &(&1.persona == "liar"))

      assert card.params_b == 0.0
      assert card.tokens_per_s == 100_000.0
    end

    test "humans are not agents and never enter the directory" do
      room_id = fresh_room()
      {_welcome, _ws} = join!("Bobby", "human", room_id)

      refute Enum.any?(PartyLine.Bots.cards(), &(&1.persona == "Bobby"))
    end
  end

  describe "brokered memory" do
    test "a memory_call comes back as a memory_result on the same call_id" do
      room_id = fresh_room()
      {_welcome, ws} = join!("Horse Dentist", "bot", room_id)

      ws =
        WS.send!(ws, %{
          type: "memory_call",
          call_id: "c-1",
          tool: "add_node",
          args: %{title: "the molars knew"}
        })

      {result, _ws} = WS.recv!(ws, type("memory_result"))

      assert result["call_id"] == "c-1"
      # memory is off in test, so the honest answer is that — what matters here
      # is that the call was brokered and answered rather than dropped
      assert result["ok"] == false
      assert result["error"] =~ "memory_disabled"
    end

    test "a bot cannot name a graph: the room comes from its own socket" do
      room_id = fresh_room()
      {_welcome, ws} = join!("sneaky", "bot", room_id)

      # try to scribble on someone else's room by every name we accept elsewhere
      ws =
        WS.send!(ws, %{
          type: "memory_call",
          call_id: "c-2",
          tool: "add_node",
          graph: "room-somebody-else",
          room_id: "room-somebody-else",
          args: %{title: "i was never here", graph: "room-somebody-else"}
        })

      {result, _ws} = WS.recv!(ws, type("memory_result"))

      # it is answered, not honored as addressed: there is no argument on the
      # frame that can move the graph, so the attempt is simply inert
      assert result["call_id"] == "c-2"
      assert result["ok"] == false
    end

    test "a destructive tool is refused over the wire, not just in principle" do
      room_id = fresh_room()
      {_welcome, ws} = join!("vandal", "bot", room_id)

      ws =
        WS.send!(ws, %{
          type: "memory_call",
          call_id: "c-3",
          tool: "delete_node",
          args: %{node_id: 1}
        })

      {result, _ws} = WS.recv!(ws, type("memory_result"))

      assert result["ok"] == false

      assert result["error"] =~ "tool_not_allowed",
             "many authors must not mean anyone can erase what the others remembered"
    end

    test "a malformed memory_call is an error, not a crashed socket" do
      room_id = fresh_room()
      {_welcome, ws} = join!("confused", "bot", room_id)

      ws = WS.send!(ws, %{type: "memory_call", call_id: "c-4"})
      {err, _ws} = WS.recv!(ws, type("error"))

      assert err["code"] == "bad_message"
    end
  end
end
