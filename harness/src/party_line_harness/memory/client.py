"""DeciduousMemory: a persona's window onto its own decision graph.

The deciduous API daemon (feat/api-server, src/api.rs) is optional
infrastructure: it may be down, half-started, or absent entirely. So the
contract here is blunt — every method swallows transport errors and
returns a neutral value (None / False / []). A memory outage degrades a
bot to "no memory", never to "crashed".

Sync httpx is deliberate: these calls run off the hot path (periodic
flushes, and a single recall folded into an already-slow generate), and
the callers wrap them in asyncio.to_thread so the event loop keeps
turning.
"""

from __future__ import annotations

import logging
from typing import Any

import httpx

log = logging.getLogger("party_line")


class DeciduousMemory:
    def __init__(self, base_url: str, token: str, graph_id: str, *, timeout: float = 5.0):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.graph_id = graph_id
        self._client = httpx.Client(
            base_url=self.base_url,
            headers={"Authorization": f"Bearer {token}"},
            timeout=timeout,
        )

    # ── low-level ──────────────────────────────────────────────────────────

    def _request(self, method: str, path: str, body: dict | None = None) -> dict | None:
        """Return the parsed JSON envelope, or None on any transport/parse error."""
        try:
            resp = self._client.request(method, path, json=body)
            return resp.json()
        except (httpx.HTTPError, ValueError) as exc:  # ValueError covers JSON decode
            log.warning("memory %s %s failed: %s", method, path, exc)
            return None

    def _tool(self, tool: str, args: dict) -> dict | None:
        """Call a graph tool; return its `result` payload, or None on error."""
        payload = self._request(
            "POST", f"/api/v1/graphs/{self.graph_id}/tools/{tool}", args
        )
        if not payload or not payload.get("ok"):
            return None
        data = payload.get("data") or {}
        if data.get("is_error"):
            return None
        result = data.get("result")
        return result if isinstance(result, dict) else {}

    # ── public surface ─────────────────────────────────────────────────────

    def ensure_graph(self) -> bool:
        """Idempotently create this bot's graph. True if it now exists."""
        payload = self._request("PUT", f"/api/v1/graphs/{self.graph_id}")
        return bool(payload and payload.get("ok"))

    def add_observation(
        self, title: str, description: str | None = None, branch: str | None = None
    ) -> int | None:
        """Record an episodic observation; return its node id, or None."""
        args: dict[str, Any] = {"node_type": "observation", "title": title}
        if description is not None:
            args["description"] = description
        if branch is not None:
            args["branch"] = branch
        result = self._tool("add_node", args)
        if result is None:
            return None
        node_id = result.get("node_id")
        return node_id if isinstance(node_id, int) else None

    def link(self, from_id: int, to_id: int, rationale: str | None = None) -> bool:
        """Link two nodes; True on success."""
        args: dict[str, Any] = {"from_id": from_id, "to_id": to_id}
        if rationale is not None:
            args["rationale"] = rationale
        return self._tool("link_nodes", args) is not None

    def query(self, sql: str, limit: int = 100) -> dict | None:
        """Run a SELECT and return the {columns, rows, ...} payload, or None."""
        payload = self._request(
            "POST", f"/api/v1/graphs/{self.graph_id}/query", {"sql": sql, "limit": limit}
        )
        if not payload or not payload.get("ok"):
            return None
        data = payload.get("data")
        return data if isinstance(data, dict) else None

    def recall_about(self, name: str, limit: int = 5) -> list[str]:
        """Observation titles that mention `name`, most recent first.

        The query endpoint takes raw SQL, so `name` is made injection-safe
        the crude-but-certain way: strip single quotes, then interpolate
        into a LIKE pattern. No quote survives to close the string literal.
        """
        safe = name.replace("'", "")
        if not safe:
            return []
        sql = (
            "SELECT title FROM decision_nodes "
            f"WHERE title LIKE '%{safe}%' ORDER BY id DESC"
        )
        data = self.query(sql, limit=limit)
        if not data:
            return []
        rows = data.get("rows") or []
        return [row[0] for row in rows if row and isinstance(row[0], str)]

    def close(self) -> None:
        try:
            self._client.close()
        except Exception:  # pragma: no cover - best-effort teardown
            pass
