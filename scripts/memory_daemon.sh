#!/usr/bin/env bash
# Start the deciduous memory daemon (locally built binary, until a release is cut).
# Creates ~/.party_line/api-token on first run; server + harness read it from there.
set -euo pipefail

DECIDUOUS_BIN="${DECIDUOUS_BIN:-$HOME/code/deciduous/target/release/deciduous}"
DATA_DIR="${PARTY_LINE_MEMORY_DIR:-$HOME/.party_line/deciduous-data}"
TOKEN_FILE="$HOME/.party_line/api-token"
PORT="${PARTY_LINE_MEMORY_PORT:-4141}"

[[ -x "$DECIDUOUS_BIN" ]] || {
  echo "deciduous binary not found at $DECIDUOUS_BIN" >&2
  echo "build it: (cd ~/code/deciduous && cargo build --release)  [branch feat/api-server]" >&2
  exit 1
}

mkdir -p "$DATA_DIR" "$(dirname "$TOKEN_FILE")"
[[ -f "$TOKEN_FILE" ]] || openssl rand -hex 16 > "$TOKEN_FILE"

if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "memory daemon already listening on :$PORT"
  exit 0
fi

echo "▸ deciduous memory daemon on http://127.0.0.1:$PORT (data: $DATA_DIR)"
exec "$DECIDUOUS_BIN" serve --api --port "$PORT" \
  --data-dir "$DATA_DIR" --token "$(cat "$TOKEN_FILE")"
