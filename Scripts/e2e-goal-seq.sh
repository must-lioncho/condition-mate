#!/usr/bin/env bash
# E2E test for STABLE goal numbers (seq) across drag-and-drop reorder.
# seq is the user-visible "id": assigned once at creation, unique, and immutable —
# reordering changes list position only, never a goal's seq.
# Launches the app headless (CM_DASHBOARD) against an isolated data dir and drives
# the real HTTP API with curl.
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
# seq for the goal whose text == $1
seq_of(){ goals_json | python3 -c "import sys,json; print(next(g['seq'] for g in json.load(sys.stdin) if g['text']=='$1'))"; }
# "text:seq" pairs in current order
seqmap(){ goals_json | python3 -c 'import sys,json; print(",".join(g["text"]+":"+str(g["seq"]) for g in json.load(sys.stdin)))'; }

echo "[1] add A,B,C -> seq 1,2,3 in creation order"
post /api/goal/add '{"text":"A"}'
post /api/goal/add '{"text":"B"}'
post /api/goal/add '{"text":"C"}'
[ "$(seqmap)" = "A:1,B:2,C:3" ] && ok "creation seq 1,2,3 ($(seqmap))" || ng "seqmap = $(seqmap)"

A=$(id_at 0); B=$(id_at 1); C=$(id_at 2)
SA=$(seq_of A); SB=$(seq_of B); SC=$(seq_of C)

echo "[2] drag C to top -> order C,A,B but seq UNCHANGED"
post /api/goal/reorder "{\"order\":[\"$C\",\"$A\",\"$B\"]}"
[ "$(texts)" = "C,A,B" ] && ok "order is C,A,B" || ng "order = $(texts)"
[ "$(seq_of A)" = "$SA" ] && [ "$(seq_of B)" = "$SB" ] && [ "$(seq_of C)" = "$SC" ] \
  && ok "each goal kept its seq (A=$SA B=$SB C=$SC)" || ng "seq changed: $(seqmap)"
[ "$(seqmap)" = "C:3,A:1,B:2" ] && ok "badges follow goals, not position ($(seqmap))" || ng "seqmap = $(seqmap)"

echo "[3] add D after reorder -> seq = max+1 = 4 (never a position number)"
post /api/goal/add '{"text":"D"}'
[ "$(seq_of D)" = "4" ] && ok "new goal seq = 4" || ng "D seq = $(seq_of D)"

echo "[4] delete a goal then add -> seq never reused (monotonic)"
post /api/goal/remove "{\"id\":\"$A\"}"
post /api/goal/add '{"text":"E"}'
[ "$(seq_of E)" = "5" ] && ok "seq monotonic, not reused (E=5)" || ng "E seq = $(seq_of E) (expected 5)"

echo "[5] seq persisted to goals.json"
HASSEQ=$(python3 -c "import json;print(all('seq' in g for g in json.load(open('$DATA_DIR/review/goals.json'))))")
[ "$HASSEQ" = "True" ] && ok "every goal has persisted seq" || ng "seq missing in goals.json"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
