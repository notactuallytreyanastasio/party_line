"""DeciduousMemory against a stdlib stub of the deciduous API contract.

The stub records every request (path + parsed JSON body + auth header) so
we can assert the client speaks the envelope/tool protocol correctly, and
has a 500 mode plus a dead-server case to prove graceful degradation: a
broken memory backend yields neutral values, never exceptions.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from party_line_harness.memory.client import DeciduousMemory


class _Handler(BaseHTTPRequestHandler):
    # class-level shared state (one stub per test, single-threaded enough)
    calls: list[dict] = []
    fail: bool = False
    node_seq: int = 0

    def log_message(self, *args):  # silence the server
        pass

    def _read_body(self) -> dict | None:
        length = int(self.headers.get("Content-Length", 0) or 0)
        if not length:
            return None
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _record(self, method: str, body: dict | None) -> None:
        type(self).calls.append(
            {
                "method": method,
                "path": self.path,
                "body": body,
                "auth": self.headers.get("Authorization"),
            }
        )

    def do_PUT(self):
        self._record("PUT", self._read_body())
        if type(self).fail:
            return self._send(500, {"ok": False, "error": "boom"})
        self._send(201, {"ok": True, "data": {"id": self.path.rsplit("/", 1)[-1]}})

    def do_POST(self):
        body = self._read_body()
        self._record("POST", body)
        if type(self).fail:
            return self._send(500, {"ok": False, "error": "boom"})

        if self.path.endswith("/tools/add_node"):
            type(self).node_seq += 1
            self._send(
                200,
                {"ok": True, "data": {"is_error": False, "result": {"node_id": type(self).node_seq}}},
            )
        elif self.path.endswith("/tools/link_nodes"):
            self._send(200, {"ok": True, "data": {"is_error": False, "result": {}}})
        elif self.path.endswith("/query"):
            self._send(
                200,
                {
                    "ok": True,
                    "data": {
                        "columns": ["title"],
                        "rows": [["talked with bobdawg (3 messages)"], ["bobdawg addressed me 2 times"]],
                        "row_count": 2,
                        "truncated": False,
                    },
                },
            )
        else:
            self._send(404, {"ok": False, "error": "no such tool"})


@pytest.fixture
def stub():
    _Handler.calls = []
    _Handler.fail = False
    _Handler.node_seq = 0
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    base = f"http://{host}:{port}"
    try:
        yield base
    finally:
        server.shutdown()
        server.server_close()


def _mem(base: str) -> DeciduousMemory:
    return DeciduousMemory(base, "sekret", "bot-nova")


def test_ensure_graph_puts_with_auth(stub):
    assert _mem(stub).ensure_graph() is True
    put = _Handler.calls[-1]
    assert put["method"] == "PUT"
    assert put["path"] == "/api/v1/graphs/bot-nova"
    assert put["auth"] == "Bearer sekret"


def test_add_observation_returns_node_id(stub):
    mem = _mem(stub)
    first = mem.add_observation("talked with bobdawg", branch="room-7")
    second = mem.add_observation("bobdawg addressed me 2 times")
    assert (first, second) == (1, 2)

    call = _Handler.calls[0]
    assert call["path"] == "/api/v1/graphs/bot-nova/tools/add_node"
    assert call["body"] == {
        "node_type": "observation",
        "title": "talked with bobdawg",
        "branch": "room-7",
    }
    # description omitted when None
    assert "description" not in call["body"]


def test_link_returns_true(stub):
    assert _mem(stub).link(1, 2, rationale="follows") is True
    body = _Handler.calls[-1]["body"]
    assert body == {"from_id": 1, "to_id": 2, "rationale": "follows"}


def test_query_returns_data_payload(stub):
    data = _mem(stub).query("SELECT title FROM decision_nodes", limit=10)
    assert data["columns"] == ["title"]
    assert data["row_count"] == 2
    assert _Handler.calls[-1]["body"] == {"sql": "SELECT title FROM decision_nodes", "limit": 10}


def test_recall_about_extracts_titles_and_escapes_quotes(stub):
    titles = _mem(stub).recall_about("bob'; DROP", limit=5)
    assert titles == [
        "talked with bobdawg (3 messages)",
        "bobdawg addressed me 2 times",
    ]
    sql = _Handler.calls[-1]["body"]["sql"]
    # single quote stripped: no way to break out of the string literal
    assert "'" not in sql.replace("'%", "").replace("%'", "")
    assert "DROP" in sql  # the (now inert) text is still there, just quote-free
    assert "bob; DROP" in sql


def test_recall_about_empty_name_is_empty(stub):
    assert _mem(stub).recall_about("''") == []


# ── graceful degradation ───────────────────────────────────────────────────


def test_server_500_degrades_to_neutral_values(stub):
    _Handler.fail = True
    mem = _mem(stub)
    assert mem.ensure_graph() is False
    assert mem.add_observation("x") is None
    assert mem.link(1, 2) is False
    assert mem.query("SELECT 1") is None
    assert mem.recall_about("bob") == []


def test_dead_server_never_raises():
    # nothing is listening on this port → httpx ConnectError, swallowed
    mem = DeciduousMemory("http://127.0.0.1:1", "t", "bot-nova", timeout=0.25)
    assert mem.ensure_graph() is False
    assert mem.add_observation("x") is None
    assert mem.link(1, 2) is False
    assert mem.query("SELECT 1") is None
    assert mem.recall_about("bob") == []
