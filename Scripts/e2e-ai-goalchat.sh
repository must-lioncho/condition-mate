#!/usr/bin/env bash
# E2E for /api/goal/aiChat — the conversation inside the AI 중복 확인 다이얼로그 where the
# user talks with Claude to decide a possible duplicate and refine the goal wording.
# Calls `claude -p` for real.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=".build/debug/ConditionManager"
[ -x "$BIN" ] || { echo "build first: swift build"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not installed"; exit 0; }

DATA_DIR="$(mktemp -d)"; ERRLOG="$(mktemp)"; PASS=0; FAIL=0
cleanup(){ [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null; rm -rf "$DATA_DIR" "$ERRLOG"; }
trap cleanup EXIT
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

CM_DATA_DIR="$DATA_DIR" CM_DASHBOARD=1 "$BIN" >/dev/null 2>"$ERRLOG" &
APP_PID=$!
PORT=""
for _ in $(seq 1 50); do
  [ -f "$DATA_DIR/dashboard.port" ] && PORT="$(cat "$DATA_DIR/dashboard.port" 2>/dev/null)"
  [ -n "$PORT" ] && break; sleep 0.2
done
[ -n "$PORT" ] || { echo "FAIL: no port"; cat "$ERRLOG"; exit 1; }
BASE="http://127.0.0.1:$PORT"
echo "server up on $BASE"
post(){ curl -s -m 200 -X POST "$BASE$1" -H 'Content-Type: application/json' -d "$2"; }

echo "[1] aiChat returns ok + non-empty reply"
R=$(post /api/goal/aiChat '{"candidate":"mpc 락업 물량 총량 검증 필요","matches":[{"seq":4,"text":"락업 물량 안내하고 의사결정 받기","why":"락업 물량 관련"}],"history":[{"role":"assistant","text":"기존 #4와 같은 맥락입니다."}],"message":"아니 이건 안내가 아니라 총량을 검증하는 작업이라 #4랑 달라. 더 구체적인 한 줄 목표로 다듬어줘."}')
echo "$R" | python3 -c 'import sys,json
d=json.load(sys.stdin)
print("    ok:",d.get("ok"))
print("    reply:",repr((d.get("reply") or "")[:80]))
print("    suggestion:",repr(d.get("suggestion")))
import sys as s
s.exit(0 if (d.get("ok") and (d.get("reply") or "").strip()) else 1)' \
  && ok "ok + reply present" || ng "no ok/reply"

echo "[2] aiChat proposes a refined goal (suggestion non-empty)"
echo "$R" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if (d.get("suggestion") or "").strip() else 1)' \
  && ok "suggestion offered" || echo "  NOTE: no suggestion this run (model-dependent, not a hard fail)"

echo "[3] empty message rejected"
R2=$(post /api/goal/aiChat '{"candidate":"x","message":"   "}')
echo "$R2" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") is False else 1)' \
  && ok "empty message -> ok:false" || ng "empty not rejected"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
