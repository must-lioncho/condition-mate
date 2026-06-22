#!/usr/bin/env bash
# E2E test for goal status (backlog/in_progress/done) + per-goal time tracking.
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
# jq-free helpers using python3
goals_json(){ state | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["review"]["goals"]))'; }
field(){ # field <index> <key>
  goals_json | python3 -c "import sys,json; g=json.load(sys.stdin); print(g[$1].get('$2'))"
}
count_status(){ goals_json | python3 -c "import sys,json; g=json.load(sys.stdin); print(sum(1 for x in g if x.get('status')=='$1'))"; }
id_at(){ field "$1" id; }

# --- scenario ---
echo "[1] add two goals -> default backlog"
post /api/goal/add '{"text":"goal A"}'
post /api/goal/add '{"text":"goal B"}'
[ "$(field 0 text)" = "goal A" ] && [ "$(field 1 text)" = "goal B" ] && ok "two goals added" || ng "goals not added"
[ "$(field 0 status)" = "backlog" ] && [ "$(field 1 status)" = "backlog" ] && ok "default status backlog" || ng "default status wrong"

A=$(id_at 0); B=$(id_at 1)

echo "[2] A -> in_progress (tracking starts)"
post /api/goal/status "{\"id\":\"$A\",\"status\":\"in_progress\"}"
[ "$(field 0 status)" = "in_progress" ] && ok "A in_progress" || ng "A not in_progress"
ST=$(field 0 startedAt); python3 -c "import sys; sys.exit(0 if float('$ST')>0 else 1)" && ok "A startedAt set" || ng "A startedAt not set"

echo "[3] wait ~2s -> A effective tracked > 0"
sleep 2.2
post /api/goal/status "{\"id\":\"$A\",\"status\":\"in_progress\"}"  # no-op, keeps running
# effective = trackedSeconds + (now - startedAt); verify server banks on transition below

echo "[4] B -> in_progress : single invariant, A reverts to backlog with banked time"
post /api/goal/status "{\"id\":\"$B\",\"status\":\"in_progress\"}"
[ "$(count_status in_progress)" = "1" ] && ok "exactly one in_progress" || ng "in_progress count = $(count_status in_progress)"
[ "$(field 0 status)" = "backlog" ] && ok "A reverted to backlog" || ng "A status = $(field 0 status)"
AT=$(field 0 trackedSeconds)
python3 -c "import sys; sys.exit(0 if float('$AT')>=2 else 1)" && ok "A banked >=2s ($AT)" || ng "A banked time too low ($AT)"
[ "$(field 0 startedAt)" = "0.0" ] || [ "$(field 0 startedAt)" = "0" ] && ok "A startedAt cleared" || ng "A startedAt not cleared ($(field 0 startedAt))"

echo "[5] B -> done : tracking stops, zero in_progress"
sleep 1.2
post /api/goal/status "{\"id\":\"$B\",\"status\":\"done\"}"
[ "$(field 1 status)" = "done" ] && ok "B done" || ng "B not done"
[ "$(count_status in_progress)" = "0" ] && ok "zero in_progress" || ng "in_progress remains"
BT=$(field 1 trackedSeconds)
python3 -c "import sys; sys.exit(0 if float('$BT')>=1 else 1)" && ok "B banked >=1s ($BT)" || ng "B banked time too low ($BT)"

echo "[6] B -> in_progress again : resumes on top of banked total"
post /api/goal/status "{\"id\":\"$B\",\"status\":\"in_progress\"}"
sleep 1.2
post /api/goal/status "{\"id\":\"$B\",\"status\":\"backlog\"}"
BT2=$(field 1 trackedSeconds)
python3 -c "import sys; sys.exit(0 if float('$BT2')>float('$BT') else 1)" && ok "B accumulated ($BT -> $BT2)" || ng "B did not accumulate ($BT -> $BT2)"

echo "[7] reject invalid status"
post /api/goal/status "{\"id\":\"$A\",\"status\":\"bogus\"}"
[ "$(field 0 status)" = "backlog" ] && ok "invalid status rejected" || ng "invalid status accepted"

echo "[8] remove a running goal"
post /api/goal/status "{\"id\":\"$A\",\"status\":\"in_progress\"}"
post /api/goal/remove "{\"id\":\"$A\"}"
[ "$(goals_json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')" = "1" ] && ok "running goal removed" || ng "remove failed"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
