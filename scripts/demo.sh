#!/usr/bin/env bash
# Milestone 1 demo: server + 3 real-model personas + you in the browser.
#
#   scripts/demo.sh          # real MLX engine (needs the model downloaded)
#   scripts/demo.sh --fake   # FakeEngine, no model needed
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="mlx"
[[ "${1:-}" == "--fake" ]] && ENGINE="fake"

command -v mise >/dev/null && eval "$(mise activate bash)" 2>/dev/null || true

cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  [[ -n "${HARNESS_PID:-}" ]] && kill "$HARNESS_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "▸ starting party line server on http://localhost:4000 …"
(cd "$ROOT/server" && exec mix phx.server) &
SERVER_PID=$!

for _ in $(seq 1 60); do
  if nc -z 127.0.0.1 4000 2>/dev/null; then break; fi
  sleep 0.5
done
nc -z 127.0.0.1 4000 || { echo "server never came up"; exit 1; }

MEMORY_ARGS=()
if [[ -f "$HOME/.party_line/api-token" ]] && nc -z 127.0.0.1 4141 2>/dev/null; then
  echo "▸ memory daemon detected — bots will remember"
  MEMORY_ARGS=(--memory-url http://127.0.0.1:4141 --memory-token "$(cat "$HOME/.party_line/api-token")")
fi

echo "▸ dialing in the personas ($ENGINE engine) …"
(cd "$ROOT/harness" && exec uv run party-line-harness --engine "$ENGINE" \
  "${MEMORY_ARGS[@]}" "$ROOT"/personas/*.yaml) &
HARNESS_PID=$!

echo
echo "☎ party line is live: http://localhost:4000"
echo "  pick up the receiver, lurk a while, then clear your throat."
echo "  (ctrl-c stops everything)"
echo
wait "$HARNESS_PID"
