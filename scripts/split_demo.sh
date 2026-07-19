#!/usr/bin/env bash
# Split-inference demo: one model, two local shard processes, glued back
# together by a pipeline host and proxied through the exchange.
#
#   scripts/split_demo.sh                 # default 8B model, exchange on :4000
#   PORT=4010 scripts/split_demo.sh       # stale dev server hogging 4000? move
#   MODEL=mlx-community/… scripts/split_demo.sh
#
# First run downloads ~4GB of weights per shard — go make coffee.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="${MODEL:-mlx-community/Meta-Llama-3.1-8B-Instruct-4bit}"
PORT="${PORT:-4000}"

command -v mise >/dev/null && eval "$(mise activate bash)" 2>/dev/null || true

LOGDIR="$(mktemp -d -t split_demo)"
echo "▸ logs live in $LOGDIR"

cleanup() {
  [[ -n "${PIPELINE_PID:-}" ]] && kill "$PIPELINE_PID" 2>/dev/null || true
  [[ -n "${SHARD_A_PID:-}" ]] && kill "$SHARD_A_PID" 2>/dev/null || true
  [[ -n "${SHARD_B_PID:-}" ]] && kill "$SHARD_B_PID" 2>/dev/null || true
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Wait for a /healthz to say "ok". Prints progress dots; dies loudly on timeout
# or if the process behind it already gave up.
wait_healthz() {
  local name="$1" url="$2" pid="$3" log="$4" timeout="$5"
  local start now
  start="$(date +%s)"
  printf '▸ waiting for %s ' "$name"
  while true; do
    if curl -s "$url" 2>/dev/null | grep -q '"ok"'; then
      echo " up"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo
      echo "✗ $name died while starting — see $log"
      exit 1
    fi
    now="$(date +%s)"
    if (( now - start > timeout )); then
      echo
      echo "✗ $name not healthy after ${timeout}s — see $log"
      echo "  (first run downloads ~4GB of weights; slow link? re-run and it resumes)"
      exit 1
    fi
    printf '.'
    sleep 2
  done
}

# ── exchange ────────────────────────────────────────────────────────────────
if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "✗ something already holds port $PORT (a stale dev server?)"
  echo "  kill it, or run: PORT=4010 scripts/split_demo.sh"
  exit 1
fi

echo "▸ starting the exchange on http://127.0.0.1:$PORT …"
(cd "$ROOT/server" && PORT="$PORT" exec mix phx.server) >"$LOGDIR/exchange.log" 2>&1 &
SERVER_PID=$!

printf '▸ waiting for the exchange '
for _ in $(seq 1 120); do
  if curl -s "http://127.0.0.1:$PORT/api/hosts" >/dev/null 2>&1; then break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo
    echo "✗ exchange died while starting — see $LOGDIR/exchange.log"
    exit 1
  fi
  printf '.'
  sleep 1
done
echo " up"
curl -s "http://127.0.0.1:$PORT/api/hosts" >/dev/null \
  || { echo "✗ exchange never answered — see $LOGDIR/exchange.log"; exit 1; }

# ── api key ─────────────────────────────────────────────────────────────────
echo "▸ minting an API key …"
TOKEN="$(cd "$ROOT/server" && mix run -e \
  '{:ok, _k, t} = PartyLine.API.Keys.mint("did:plc:split-demo", "split-demo"); IO.puts("TOKEN=" <> t)' \
  2>"$LOGDIR/mint.log" | grep '^TOKEN=' | cut -d= -f2- || true)"
[[ -n "$TOKEN" ]] || { echo "✗ could not mint an API key — see $LOGDIR/mint.log"; exit 1; }

# ── the two halves ──────────────────────────────────────────────────────────
echo "▸ dealing the model in half ($MODEL) …"
echo "  (first run pulls ~4GB of weights — the dots below are honest work)"

(cd "$ROOT/harness" && exec uv run party-line-harness serve-shard \
  --model "$MODEL" --stage 0/2 --port 8380 --no-tailscale \
  --server "http://127.0.0.1:$PORT" --exchange-key "$TOKEN" \
  --name shard-A) >"$LOGDIR/shard-A.log" 2>&1 &
SHARD_A_PID=$!

(cd "$ROOT/harness" && exec uv run party-line-harness serve-shard \
  --model "$MODEL" --stage 1/2 --port 8381 --no-tailscale \
  --server "http://127.0.0.1:$PORT" --exchange-key "$TOKEN" \
  --name shard-B) >"$LOGDIR/shard-B.log" 2>&1 &
SHARD_B_PID=$!

wait_healthz "shard-A (layers, first half)"  "http://127.0.0.1:8380/healthz" "$SHARD_A_PID" "$LOGDIR/shard-A.log" 900
wait_healthz "shard-B (layers, second half)" "http://127.0.0.1:8381/healthz" "$SHARD_B_PID" "$LOGDIR/shard-B.log" 900

# ── the seam ────────────────────────────────────────────────────────────────
echo "▸ starting the pipeline host (stitches the halves back together) …"
(cd "$ROOT/harness" && exec uv run party-line-harness pipeline-host \
  --model "$MODEL" --port 8379 --no-tailscale \
  --server "http://127.0.0.1:$PORT" --exchange-key "$TOKEN" \
  --name assembled-8b) >"$LOGDIR/pipeline-host.log" 2>&1 &
PIPELINE_PID=$!

wait_healthz "pipeline host" "http://127.0.0.1:8379/healthz" "$PIPELINE_PID" "$LOGDIR/pipeline-host.log" 300

printf '▸ waiting for the exchange to see the assembled pipeline '
READY=""
for _ in $(seq 1 60); do
  if curl -s "http://127.0.0.1:$PORT/api/pipelines" 2>/dev/null | grep -q '"ready":true'; then
    READY=1
    break
  fi
  printf '.'
  sleep 2
done
echo
[[ -n "$READY" ]] || {
  echo "✗ pipeline never showed ready on /api/pipelines — see $LOGDIR/pipeline-host.log"
  exit 1
}
echo "▸ pipeline assembled and ready"

# ── one real completion, end to end ─────────────────────────────────────────
echo "▸ firing one completion through the whole stack …"
BODY="$(printf '{"model":"%s","max_tokens":60,"temperature":0,"messages":[{"role":"user","content":"In one sentence, why do cats knead soft blankets?"}]}' "$MODEL")"
RESPONSE="$(curl -s "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$BODY" || true)"
[[ -n "$RESPONSE" ]] || { echo "✗ the completion call came back empty — see $LOGDIR"; exit 1; }

echo
echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
echo

ANSWER="$(echo "$RESPONSE" | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])' \
  2>/dev/null || true)"
[[ -n "$ANSWER" ]] && echo "☎ the assembled model says: $ANSWER"

# ── curtain call ────────────────────────────────────────────────────────────
cat <<SUMMARY

☎ split inference is live.
  One model, cut in half: shard-A holds the first half of the layers,
  shard-B the second (0-15 / 16-31 on the default 8B). Every token you
  just read crossed a process boundary mid-forward-pass, got stitched
  together by the pipeline host, and came back through the exchange like
  nothing happened.

  try another one:

  curl -s http://127.0.0.1:$PORT/v1/chat/completions \\
    -H "Authorization: Bearer $TOKEN" \\
    -H "Content-Type: application/json" \\
    -d '{"model":"$MODEL","max_tokens":120,"messages":[{"role":"user","content":"your question here"}]}'

  logs: $LOGDIR
  (ctrl-c hangs up and tears the whole thing down)

SUMMARY

wait "$PIPELINE_PID"
