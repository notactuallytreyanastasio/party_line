defmodule PartyLine.Memory.IngestTest do
  use ExUnit.Case, async: true

  alias PartyLine.Memory.Ingest

  # ── In-test stub of the deciduous API ─────────────────────────────────────
  #
  # A tiny plug served by Bandit on an ephemeral port. It implements just
  # enough of the contract for ingestion and records every call (method, path,
  # decoded body) into an Agent the test reads back. The Agent also carries the
  # node-id counter and a status knob so a test can force 500s.

  defmodule Stub do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)

      Agent.update(agent, fn s ->
        %{s | calls: s.calls ++ [%{method: conn.method, path: conn.request_path, body: body}]}
      end)

      status =
        Agent.get_and_update(agent, fn
          %{plan: [next | rest]} = s -> {next, %{s | plan: rest}}
          s -> {s.status, s}
        end)

      case status do
        200 -> ok(conn, agent)
        status -> error(conn, status)
      end
    end

    defp ok(conn, agent) do
      data =
        cond do
          String.ends_with?(conn.request_path, "/tools/add_node") ->
            n = Agent.get_and_update(agent, fn s -> {s.seq + 1, %{s | seq: s.seq + 1}} end)
            %{"is_error" => false, "result" => %{"node_id" => n}}

          String.ends_with?(conn.request_path, "/tools/link_nodes") ->
            %{"is_error" => false, "result" => %{}}

          true ->
            # PUT graph create
            %{"created" => true}
        end

      send_json(conn, 200, %{"ok" => true, "data" => data})
    end

    defp error(conn, status) do
      send_json(conn, status, %{"ok" => false, "error" => "boom"})
    end

    defp send_json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp start_stub(status \\ 200) do
    {:ok, agent} = Agent.start_link(fn -> %{calls: [], seq: 0, status: status, plan: []} end)
    {:ok, srv} = Bandit.start_link(plug: {Stub, agent: agent}, port: 0, startup_log: false)
    on_exit(fn -> if Process.alive?(srv), do: Process.exit(srv, :normal) end)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(srv)
    {agent, "http://127.0.0.1:#{port}"}
  end

  defp start_ingest(api_url, opts \\ []) do
    config = %{api_url: api_url, token: "test-token", graph: "party-line-root"}
    enabled = Keyword.get(opts, :enabled, true)

    start_supervised!(
      {Ingest, name: nil, enabled: enabled, config: config},
      id: {:ingest, System.unique_integer([:positive])}
    )
  end

  defp calls(agent), do: Agent.get(agent, & &1.calls)

  defp calls_to(agent, suffix) do
    agent |> calls() |> Enum.filter(&String.ends_with?(&1.path, suffix))
  end

  defp msg(seq, name, body, mentions \\ []) do
    %{
      type: :message,
      seq: seq,
      message_id: "m-#{seq}",
      ts: "2026-07-15T00:00:0#{seq}Z",
      sender: %{participant_id: "p-1", name: name, kind: :bot},
      body: body,
      mentions: mentions
    }
  end

  defp sync(ingest), do: GenServer.call(ingest, :sync)

  # Queue per-request statuses; once exhausted the stub falls back to :status.
  defp plan(agent, statuses), do: Agent.update(agent, fn s -> %{s | plan: statuses} end)

  # ── Tests ──────────────────────────────────────────────────────────────────

  test "(a) three messages produce three add_node calls and two follows links in order" do
    {agent, url} = start_stub()
    ingest = start_ingest(url)

    Ingest.record_message(ingest, "room-1", msg(1, "Ada", "first"))
    Ingest.record_message(ingest, "room-1", msg(2, "Bo", "second"))
    Ingest.record_message(ingest, "room-1", msg(3, "Cy", "third"))
    sync(ingest)

    # graph ensured exactly once
    assert length(calls_to(agent, "/graphs/party-line-root")) == 1

    adds = calls_to(agent, "/tools/add_node")
    assert length(adds) == 3
    assert Enum.map(adds, & &1.body["title"]) == ["Ada: first", "Bo: second", "Cy: third"]
    assert Enum.all?(adds, &(&1.body["node_type"] == "observation"))
    assert Enum.all?(adds, &(&1.body["branch"] == "room-1"))

    links = calls_to(agent, "/tools/link_nodes")
    assert length(links) == 2
    assert Enum.all?(links, &(&1.body["rationale"] == "follows"))
    # chained head->tail: 1->2 then 2->3 (node ids assigned in add order)
    assert Enum.map(links, &{&1.body["from_id"], &1.body["to_id"]}) == [{1, 2}, {2, 3}]
  end

  test "(b) a mention creates the participant node once and reuses it on repeat" do
    {agent, url} = start_stub()
    ingest = start_ingest(url)

    mention = %{participant_id: "p-2", name: "Bo", kind: :bot}
    Ingest.record_message(ingest, "room-1", msg(1, "Ada", "hi @Bo", [mention]))
    Ingest.record_message(ingest, "room-1", msg(2, "Cy", "yo @Bo", [mention]))
    sync(ingest)

    adds = calls_to(agent, "/tools/add_node")
    participant_adds = Enum.filter(adds, &String.starts_with?(&1.body["title"], "participant:"))

    # exactly ONE participant node despite two mentions of the same name
    assert length(participant_adds) == 1
    assert hd(participant_adds).body["title"] == "participant: Bo (bot)"

    mentions_links =
      calls_to(agent, "/tools/link_nodes")
      |> Enum.filter(&(&1.body["rationale"] == "mentions"))

    # one "mentions" edge per message
    assert length(mentions_links) == 2
    # both edges point at the same cached participant node
    assert mentions_links |> Enum.map(& &1.body["to_id"]) |> Enum.uniq() |> length() == 1
  end

  test "(c) presence events chain with follows" do
    {agent, url} = start_stub()
    ingest = start_ingest(url)

    Ingest.record_presence(ingest, "room-1", :joined, %{
      participant_id: "p-1",
      name: "Ada",
      kind: :bot
    })

    Ingest.record_presence(ingest, "room-1", :announced, %{
      participant_id: "p-2",
      name: "Bo",
      kind: :human
    })

    Ingest.record_presence(ingest, "room-1", :left, %{
      participant_id: "p-1",
      name: "Ada",
      kind: :bot
    })

    sync(ingest)

    adds = calls_to(agent, "/tools/add_node")

    assert Enum.map(adds, & &1.body["title"]) == [
             "presence: joined Ada",
             "presence: announced Bo",
             "presence: left Ada"
           ]

    links = calls_to(agent, "/tools/link_nodes")
    assert length(links) == 2
    assert Enum.all?(links, &(&1.body["rationale"] == "follows"))
    assert Enum.map(links, &{&1.body["from_id"], &1.body["to_id"]}) == [{1, 2}, {2, 3}]
  end

  test "(d) with enabled: false nothing is posted" do
    {agent, url} = start_stub()
    ingest = start_ingest(url, enabled: false)

    Ingest.record_message(ingest, "room-1", msg(1, "Ada", "first"))

    Ingest.record_presence(ingest, "room-1", :joined, %{
      participant_id: "p-1",
      name: "Ada",
      kind: :bot
    })

    sync(ingest)

    assert calls(agent) == []
  end

  test "(e) client errors don't crash Ingest; the next event is still processed" do
    {agent, url} = start_stub(500)
    ingest = start_ingest(url)

    Ingest.record_message(ingest, "room-1", msg(1, "Ada", "first"))
    sync(ingest)
    assert Process.alive?(ingest)

    # the daemon recovers; the next event flows through normally
    Agent.update(agent, fn s -> %{s | status: 200} end)
    Ingest.record_message(ingest, "room-1", msg(2, "Bo", "second"))
    sync(ingest)

    assert Process.alive?(ingest)
    assert calls_to(agent, "/tools/add_node") != []
  end

  test "(f) the follows chain skips a dropped message and rejoins at the next success" do
    {agent, url} = start_stub()
    ingest = start_ingest(url)

    Ingest.record_message(ingest, "room-1", msg(1, "Ada", "first"))
    sync(ingest)

    # daemon hiccup: the second message is dropped
    Agent.update(agent, fn s -> %{s | status: 500} end)
    Ingest.record_message(ingest, "room-1", msg(2, "Bo", "lost to the void"))
    sync(ingest)

    # daemon recovers: the third message must chain onto the FIRST, not the drop
    Agent.update(agent, fn s -> %{s | status: 200} end)
    Ingest.record_message(ingest, "room-1", msg(3, "Cy", "third"))
    sync(ingest)

    # node ids: msg1 -> 1, msg2 dropped (no id assigned), msg3 -> 2
    assert [%{body: %{"from_id" => 1, "to_id" => 2, "rationale" => "follows"}}] =
             calls_to(agent, "/tools/link_nodes")
  end

  test "(g) a failure mid-mentions drops the remaining mentions but not the pipeline" do
    {agent, url} = start_stub()
    ingest = start_ingest(url)

    mentions = [
      %{participant_id: "p-2", name: "horse dentist", kind: :bot},
      %{participant_id: "p-3", name: "erowid smoothie", kind: :bot}
    ]

    # requests: PUT graph, add message node, add participant 1, link mentions (FAILS)
    plan(agent, [200, 200, 200, 500])

    Ingest.record_message(
      ingest,
      "room-1",
      msg(1, "Ada", "hi @horse dentist and @erowid smoothie", mentions)
    )

    sync(ingest)
    assert Process.alive?(ingest)

    # the second mention was dropped: its participant node is never even attempted
    participant_adds =
      agent
      |> calls_to("/tools/add_node")
      |> Enum.filter(&String.starts_with?(&1.body["title"], "participant:"))

    assert Enum.map(participant_adds, & &1.body["title"]) == ["participant: horse dentist (bot)"]

    # the pipeline is intact: the next message ingests and chains onto message 1
    Ingest.record_message(ingest, "room-1", msg(2, "Bo", "second"))
    sync(ingest)

    follows =
      agent
      |> calls_to("/tools/link_nodes")
      |> Enum.filter(&(&1.body["rationale"] == "follows"))

    # node ids: msg1 -> 1, participant -> 2, msg2 -> 3
    assert Enum.map(follows, &{&1.body["from_id"], &1.body["to_id"]}) == [{1, 3}]
  end

  test "(h) multi-word lowercase persona names flow through intact" do
    {agent, url} = start_stub()
    ingest = start_ingest(url)

    Ingest.record_message(
      ingest,
      "room-1",
      msg(1, "erowid smoothie", "the tea is kicking in", [
        %{participant_id: "p-2", name: "horse dentist", kind: :bot}
      ])
    )

    sync(ingest)

    titles = agent |> calls_to("/tools/add_node") |> Enum.map(& &1.body["title"])
    assert "erowid smoothie: the tea is kicking in" in titles
    assert "participant: horse dentist (bot)" in titles
  end

  test "(i) long bodies are truncated in the title but carried whole in the description" do
    {agent, url} = start_stub()
    ingest = start_ingest(url)

    body = String.duplicate("a", 150)
    Ingest.record_message(ingest, "room-1", msg(1, "Ada", body))
    sync(ingest)

    assert [add] = calls_to(agent, "/tools/add_node")
    assert add.body["title"] == "Ada: " <> String.duplicate("a", 100)
    assert add.body["description"] == body
  end

  test "(j) missing sender and participant names fall back to ?" do
    {agent, url} = start_stub()
    ingest = start_ingest(url)

    Ingest.record_message(ingest, "room-1", %{body: "who said that"})
    Ingest.record_presence(ingest, "room-1", :joined, %{participant_id: "p-9"})
    sync(ingest)

    titles = agent |> calls_to("/tools/add_node") |> Enum.map(& &1.body["title"])
    assert titles == ["?: who said that", "presence: joined ?"]
  end

  test "(k) record_* against a never-started server returns :ok without crashing" do
    assert :ok = Ingest.record_message(:never_started_ingest, "room-1", msg(1, "Ada", "hi"))

    assert :ok =
             Ingest.record_presence(:never_started_ingest, "room-1", :joined, %{name: "Ada"})
  end
end
