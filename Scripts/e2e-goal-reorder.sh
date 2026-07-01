#!/usr/bin/env bash
# E2E test for drag-and-drop priority reorder (/api/goal/reorder).
# Launches the app headless (CM_DASHBOARD) against an isolated data dir (CM_DATA_DIR),
# discovers the loopback port from stderr, and drives the real HTTP API with curl.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=".build/debug/ConditionManager"
[ -x "$BIN" ] || { echo "build first: swift build"; exit 1; }

DATA_DIR="$(mktemp -d)"
ERRLOG="$(mktemp)"
PASS=0; FAIL=0
cleanup(){ [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null; rm -rf "$DATA_DIR" "$ERRLOG"; }
trap cleanup EXIT

ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# --- launch headless server ---
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

post(){ curl -s -X POST "$BASE$1" -H 'Content-Type: application/json' -d "$2" >/dev/null; }
state(){ curl -s "$BASE/data.json"; }
goals_json(){ state | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["review"]["goals"]))'; }
texts(){ goals_json | python3 -c 'import sys,json; print(",".join(g["text"] for g in json.load(sys.stdin)))'; }
id_at(){ goals_json | python3 -c "import sys,json; print(json.load(sys.stdin)[$1]['id'])"; }

# --- scenario ---
echo "[1] add four goals -> creation order A,B,C,D"
post /api/goal/add '{"text":"A"}'
post /api/goal/add '{"text":"B"}'
post /api/goal/add '{"text":"C"}'
post /api/goal/add '{"text":"D"}'
[ "$(texts)" = "A,B,C,D" ] && ok "initial order A,B,C,D" || ng "initial order = $(texts)"

A=$(id_at 0); B=$(id_at 1); C=$(id_at 2); D=$(id_at 3)

echo "[2] drag D to top -> D,A,B,C"
post /api/goal/reorder "{\"order\":[\"$D\",\"$A\",\"$B\",\"$C\"]}"
[ "$(texts)" = "D,A,B,C" ] && ok "D moved to top" || ng "order = $(texts)"

echo "[3] drag A to bottom -> D,B,C,A"
post /api/goal/reorder "{\"order\":[\"$D\",\"$B\",\"$C\",\"$A\"]}"
[ "$(texts)" = "D,B,C,A" ] && ok "A moved to bottom" || ng "order = $(texts)"

echo "[4] partial order (only C,A listed) -> listed first, rest keep relative order"
# reorderGoals appends missing ids (D,B) in their current relative order after the listed ones.
post /api/goal/reorder "{\"order\":[\"$C\",\"$A\"]}"
[ "$(texts)" = "C,A,D,B" ] && ok "partial reorder safe ($(texts))" || ng "partial reorder = $(texts)"

echo "[5] bogus id in order is ignored, no goal dropped/duplicated"
post /api/goal/reorder "{\"order\":[\"ghost\",\"$B\",\"$A\",\"$C\",\"$D\"]}"
N=$(goals_json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')
[ "$N" = "4" ] && ok "count stable at 4 with bogus id" || ng "count = $N"
[ "$(texts)" = "B,A,C,D" ] && ok "valid ids still applied ($(texts))" || ng "order = $(texts)"

echo "[6] reorder survives reload (persisted to goals.json)"
post /api/goal/reorder "{\"order\":[\"$A\",\"$B\",\"$C\",\"$D\"]}"
grep -q '"text":"A"' "$DATA_DIR"/review/goals.json && ok "goals.json written" || ng "goals.json missing"
FIRST=$(python3 -c "import json;print(json.load(open('$DATA_DIR/review/goals.json'))[0]['text'])")
[ "$FIRST" = "A" ] && ok "persisted order head = A" || ng "persisted head = $FIRST"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
