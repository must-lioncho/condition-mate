#!/usr/bin/env bash
# E2E test for the AI추가 dedup queue (the "later" pile) and the /api/goal/aiAdd pass.
# Launches the app headless against an isolated data dir and drives the real HTTP API.
# The aiAdd assertion is best-effort: if `claude` is not installed it must FALL BACK to
# a plain add (never a hard gate), so the test accepts either a verdict or a fallback.
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

# The headless app publishes its loopback port to <data_dir>/dashboard.port.
wait_port(){
  local p=""
  for _ in $(seq 1 50); do
    [ -f "$DATA_DIR/dashboard.port" ] && p="$(cat "$DATA_DIR/dashboard.port" 2>/dev/null)"
    [ -n "$p" ] && { echo "$p"; return 0; }
    sleep 0.2
  done
  return 1
}

CM_DATA_DIR="$DATA_DIR" CM_DASHBOARD=1 "$BIN" >/dev/null 2>"$ERRLOG" &
APP_PID=$!
PORT="$(wait_port)" || { echo "FAIL: server did not report a port"; cat "$ERRLOG"; exit 1; }
BASE="http://127.0.0.1:$PORT"
echo "server up on $BASE (data: $DATA_DIR)"

post(){ curl -s -X POST "$BASE$1" -H 'Content-Type: application/json' -d "$2"; }
state(){ curl -s "$BASE/data.json"; }
queue_json(){ state | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["review"]["aiQueue"]))'; }
goals_json(){ state | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["review"]["goals"]))'; }
qlen(){ queue_json | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))'; }
glen(){ goals_json | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))'; }
qfield(){ queue_json | python3 -c "import sys,json; q=json.load(sys.stdin); print(q[$1].get('$2'))"; }
qid(){ queue_json | python3 -c "import sys,json; q=json.load(sys.stdin); print(q[$1]['id'])"; }

echo "[1] aiQueue starts empty"
[ "$(qlen)" = "0" ] && ok "empty queue" || ng "queue not empty"

echo "[2] queue/add parks a candidate (the 'later' action)"
post /api/goal/queue/add '{"text":"워커 모니터링","note":"#2와 유사","matches":[{"seq":2,"text":"워커 리소스 모니터링","why":"의도 동일"}]}' >/dev/null
[ "$(qlen)" = "1" ] && ok "one item queued" || ng "queue add failed"
[ "$(qfield 0 text)" = "워커 모니터링" ] && ok "queued text correct" || ng "queued text wrong"
[ "$(qfield 0 note)" = "#2와 유사" ] && ok "queued note correct" || ng "queued note wrong"

echo "[3] queue/resolve edit rewrites text, keeps it queued"
QID=$(qid 0)
post /api/goal/queue/resolve "{\"id\":\"$QID\",\"action\":\"edit\",\"text\":\"워커 자원 모니터링\"}" >/dev/null
[ "$(qlen)" = "1" ] && [ "$(qfield 0 text)" = "워커 자원 모니터링" ] && ok "edit kept item, updated text" || ng "edit failed"

echo "[4] queue/resolve add promotes to a real goal and dequeues"
G0=$(glen)
post /api/goal/queue/resolve "{\"id\":\"$QID\",\"action\":\"add\"}" >/dev/null
[ "$(qlen)" = "0" ] && ok "item dequeued" || ng "item not dequeued"
[ "$(glen)" = "$((G0+1))" ] && ok "goal created from queue" || ng "goal not created"

echo "[5] queue/resolve skip drops without creating a goal"
post /api/goal/queue/add '{"text":"버릴 후보"}' >/dev/null
QID2=$(qid 0); G1=$(glen)
post /api/goal/queue/resolve "{\"id\":\"$QID2\",\"action\":\"skip\"}" >/dev/null
[ "$(qlen)" = "0" ] && [ "$(glen)" = "$G1" ] && ok "skip dropped item, no goal" || ng "skip failed"

echo "[6] queue survives restart (persisted to ai-queue.json)"
post /api/goal/queue/add '{"text":"영속 테스트"}' >/dev/null
kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
rm -f "$DATA_DIR/dashboard.port"; : > "$ERRLOG"
CM_DATA_DIR="$DATA_DIR" CM_DASHBOARD=1 "$BIN" >/dev/null 2>"$ERRLOG" &
APP_PID=$!
PORT="$(wait_port)" || { echo "FAIL: server did not come back up"; exit 1; }
BASE="http://127.0.0.1:$PORT"
[ "$(qlen)" = "1" ] && [ "$(qfield 0 text)" = "영속 테스트" ] && ok "queue persisted across restart" || ng "queue not persisted"

echo "[7] aiAdd is best-effort: returns ok-verdict OR falls back gracefully"
RES=$(post /api/goal/aiAdd '{"text":"완전히 새로운 무언가 zzz"}')
echo "    aiAdd -> $RES"
echo "$RES" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if "ok" in d else 1)' \
  && ok "aiAdd returned a structured verdict" || ng "aiAdd response malformed"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
