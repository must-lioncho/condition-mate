#!/usr/bin/env bash
# E2E test for the concurrency-gated AI-work fields (energy / agents / tokens / value).
# Launches the app headless (CM_DASHBOARD) against an isolated data dir (CM_DATA_DIR),
# discovers the loopback port from stderr, and drives the real HTTP API with curl.
# Verifies the Swift side that energy.test.js cannot: JSON serialization, the POST
# handlers, server-side clamping, and on-disk persistence across a restart.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=".build/debug/ConditionMate"
[ -x "$BIN" ] || { echo "build first: swift build"; exit 1; }

DATA_DIR="$(mktemp -d)"
ERRLOG="$(mktemp)"
PASS=0; FAIL=0
cleanup(){ [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null; rm -rf "$DATA_DIR" "$ERRLOG"; }
trap cleanup EXIT

ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Launch the headless server against DATA_DIR and report its loopback port.
launch(){
  : > "$ERRLOG"
  CM_DATA_DIR="$DATA_DIR" CM_DASHBOARD=1 "$BIN" 2>"$ERRLOG" &
  APP_PID=$!
  PORT=""
  for _ in $(seq 1 50); do
    PORT=$(grep -oE 'http://127\.0\.0\.1:[0-9]+' "$ERRLOG" | head -1 | grep -oE '[0-9]+$')
    [ -n "$PORT" ] && break
    sleep 0.2
  done
  [ -n "$PORT" ] || { echo "FAIL: server did not report a port"; cat "$ERRLOG"; exit 1; }
  BASE="http://127.0.0.1:$PORT"
  echo "server up on $BASE (data: $DATA_DIR)"
}

post(){ curl -s -X POST "$BASE$1" -H 'Content-Type: application/json' -d "$2" >/dev/null; }
state(){ curl -s "$BASE/data.json"; }
goals_json(){ state | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["review"]["goals"]))'; }
field(){ goals_json | python3 -c "import sys,json; g=json.load(sys.stdin); print(g[$1].get('$2'))"; }
count_status(){ goals_json | python3 -c "import sys,json; g=json.load(sys.stdin); print(sum(1 for x in g if x.get('status')=='$1'))"; }
agents_len(){ goals_json | python3 -c "import sys,json; g=json.load(sys.stdin); print(len(g[$1].get('agents',[])))"; }
agent_at(){ goals_json | python3 -c "import sys,json; g=json.load(sys.stdin); print(g[$1].get('agents',[])[$2])"; }
kids_of(){ goals_json | python3 -c "import sys,json; g=json.load(sys.stdin); pid=g[$1].get('id'); print(sum(1 for x in g if x.get('parent')==pid))"; }
id_at(){ field "$1" id; }

launch

echo "[1] add a parent goal + two child tasks -> default backlog, fields default on parent"
post /api/goal/add '{"text":"big goal"}'   # index 0 = parent
post /api/goal/add '{"text":"task A"}'      # index 1 = child
post /api/goal/add '{"text":"task B"}'      # index 2 = child
[ "$(field 0 energy)" = "0" ] && [ "$(field 0 tokens)" = "0" ] && [ "$(field 0 value)" = "0" ] && ok "parent fields default to 0" || ng "parent field defaults wrong"
[ "$(agents_len 0)" = "0" ] && ok "parent agents default empty" || ng "agents not empty"
P=$(id_at 0); A=$(id_at 1); B=$(id_at 2)

echo "[2] nest both tasks under the parent and run them -> parent active, 2 in_progress"
post /api/goal/parent "{\"id\":\"$A\",\"parent\":\"$P\"}"
post /api/goal/parent "{\"id\":\"$B\",\"parent\":\"$P\"}"
[ "$(kids_of 0)" = "2" ] && ok "parent has 2 children" || ng "parent kids = $(kids_of 0)"
post /api/goal/status "{\"id\":\"$A\",\"status\":\"in_progress\"}"
post /api/goal/status "{\"id\":\"$B\",\"status\":\"in_progress\"}"
# A parent with an in_progress child is "active" (on_track) in the dashboard rollup; the
# server stores child status, the client derives on_track. Here we confirm the children run.
[ "$(count_status in_progress)" = "2" ] && ok "two children in_progress (parent active)" || ng "in_progress count = $(count_status in_progress)"

echo "[3] manage energy/value/token at the PARENT level (not per task)"
post /api/goal/energy "{\"id\":\"$P\",\"energy\":40}"
[ "$(field 0 energy)" = "40" ] && ok "parent energy round-trips" || ng "parent energy not persisted ($(field 0 energy))"
[ "$(field 1 energy)" = "0" ] && [ "$(field 2 energy)" = "0" ] && ok "child tasks carry no energy (parent-only)" || ng "energy leaked onto tasks"

echo "[4] energy clamps to 0..100 server-side"
post /api/goal/energy "{\"id\":\"$P\",\"energy\":150}"
[ "$(field 0 energy)" = "100" ] && ok "150 clamped to 100" || ng "over-100 not clamped ($(field 0 energy))"
post /api/goal/energy "{\"id\":\"$P\",\"energy\":-10}"
[ "$(field 0 energy)" = "0" ] && ok "-10 clamped to 0" || ng "negative not clamped ($(field 0 energy))"
post /api/goal/energy "{\"id\":\"$P\",\"energy\":40}"

echo "[5] assign agents on the parent (comma + space separated, trimmed)"
post /api/goal/agents "{\"id\":\"$P\",\"agents\":\"agent1, agent2\"}"
[ "$(agents_len 0)" = "2" ] && ok "two agents parsed" || ng "agent count = $(agents_len 0)"
{ [ "$(agent_at 0 0)" = "agent1" ] && [ "$(agent_at 0 1)" = "agent2" ]; } && ok "agent names round-trip" || ng "agent names wrong"
post /api/goal/agents "{\"id\":\"$P\",\"agents\":\"  agent1   agent2  agent3 \"}"
[ "$(agents_len 0)" = "3" ] && ok "space-split + trim -> 3 agents" || ng "space split wrong ($(agents_len 0))"

echo "[6] tokens + value on the parent; ROI is value/tokens"
post /api/goal/tokens "{\"id\":\"$P\",\"tokens\":50}"
post /api/goal/value "{\"id\":\"$P\",\"value\":100}"
[ "$(field 0 tokens)" = "50" ] && [ "$(field 0 value)" = "100" ] && ok "tokens/value round-trip (ROI 100/50 = 2.0)" || ng "tokens/value not persisted"
post /api/goal/tokens "{\"id\":\"$P\",\"tokens\":-5}"
[ "$(field 0 tokens)" = "0" ] && ok "negative tokens clamped to 0" || ng "tokens not clamped ($(field 0 tokens))"
post /api/goal/tokens "{\"id\":\"$P\",\"tokens\":50}"

echo "[7] persistence across restart -> goals.json keeps parent AI-work fields"
EBEFORE=$(field 0 energy); TBEFORE=$(field 0 tokens); VBEFORE=$(field 0 value); AGBEFORE=$(agents_len 0)
kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""
launch
[ "$(field 0 energy)" = "$EBEFORE" ] && ok "energy survived restart ($EBEFORE)" || ng "energy lost ($(field 0 energy) != $EBEFORE)"
[ "$(field 0 tokens)" = "$TBEFORE" ] && [ "$(field 0 value)" = "$VBEFORE" ] && ok "tokens/value survived restart" || ng "tokens/value lost"
[ "$(agents_len 0)" = "$AGBEFORE" ] && ok "agents survived restart ($AGBEFORE)" || ng "agents lost ($(agents_len 0) != $AGBEFORE)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
