#!/usr/bin/env bash
# E2E for the goal page (/goal?n=NN): the core/detail two-version split, the four
# canonical section cards, legacy-flat -> goal-detail.md migration, and the per-goal
# "목표 명확화" messenger endpoints. Drives the real HTTP API against a headless
# throwaway instance. The optional chat-send step calls `claude -p` for real, so it
# is skipped when the claude CLI is absent.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=".build/debug/ConditionMate"
[ -x "$BIN" ] || { echo "build first: swift build"; exit 1; }

DATA_DIR="$(mktemp -d)"; ERRLOG="$(mktemp)"
PASS=0; FAIL=0
cleanup(){ [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null; rm -rf "$DATA_DIR" "$ERRLOG"; }
trap cleanup EXIT
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

CM_DATA_DIR="$DATA_DIR" CM_DASHBOARD=1 "$BIN" 2>"$ERRLOG" &
APP_PID=$!
PORT=""
for _ in $(seq 1 50); do
  [ -f "$DATA_DIR/dashboard.port" ] && PORT="$(cat "$DATA_DIR/dashboard.port" 2>/dev/null)"
  [ -n "$PORT" ] && break; sleep 0.2
done
[ -n "$PORT" ] || { echo "FAIL: server did not report a port"; cat "$ERRLOG"; exit 1; }
BASE="http://127.0.0.1:$PORT"
echo "server up on $BASE (data: $DATA_DIR)"

post(){ curl -s -X POST "$BASE$1" -H 'Content-Type: application/json' -d "$2" >/dev/null; }
page(){ curl -s "$BASE/goal?n=$1"; }
has(){ echo "$1" | grep -qF "$2"; }

echo "[setup] create two goals (seq 1, 2)"
post /api/goal/add '{"text":"무인 곡생성 골"}'
post /api/goal/add '{"text":"마이그레이션 골"}'

echo "[1] write core/detail for goal-01, render the page"
mkdir -p "$DATA_DIR/issue/goal-01"
cat > "$DATA_DIR/issue/goal-01/goal-detail.md" <<'MD'
## 문제정의
DETAIL_PROBLEM 쿠키 모드 422 정의.

## 예상결과
DETAIL_RESULT 200 OK + 다운로드.

## 예상해결방안
DETAIL_PLAN cURL 캡처 후 비교.

## 예상테스트시나리오
DETAIL_TEST 쿠키 모드 생성 200.
MD
cat > "$DATA_DIR/issue/goal-01/goal-core.md" <<'MD'
## 문제정의
CORE_PROBLEM 무인 생성이 막힘.

## 예상결과
CORE_RESULT 무인 생성 성공.
MD
H=$(page 1)
has "$H" "핵심 버전" && has "$H" "디테일 버전" && ok "version toggle present" || ng "version toggle missing"
has "$H" "목표 명확화 대화" && ok "messenger panel present" || ng "messenger panel missing"
for s in 문제정의 예상결과 예상해결방안 예상테스트시나리오; do
  has "$H" "$s" || ng "section card missing: $s"
done
has "$H" CORE_PROBLEM && has "$H" CORE_RESULT && ok "core version content rendered" || ng "core content missing"
has "$H" DETAIL_PROBLEM && has "$H" DETAIL_TEST && ok "detail version content rendered" || ng "detail content missing"
has "$H" "아직 작성되지 않았습니다" && ok "missing-section placeholder shown (core has only 2 of 4)" || ng "placeholder missing"

echo "[2] legacy flat goal-02.md migrates to goal-02/goal-detail.md on open"
cat > "$DATA_DIR/issue/goal-02.md" <<'MD'
## 문제정의
LEGACY_FLAT 내용.
MD
H2=$(page 2)
has "$H2" LEGACY_FLAT && ok "legacy content rendered under detail" || ng "legacy content not rendered"
[ -f "$DATA_DIR/issue/goal-02/goal-detail.md" ] && ok "migrated to goal-02/goal-detail.md" || ng "migration did not move the file"
[ -f "$DATA_DIR/issue/goal-02.md" ] && ng "legacy flat file still present (should be moved)" || ok "legacy flat file removed"

echo "[3] per-goal chat starts empty + reset is a no-op on empty"
N=$(curl -s "$BASE/api/goal/chat?seq=1" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["messages"]))')
[ "$N" = "0" ] && ok "goal chat starts empty" || ng "expected empty, got $N"
curl -s -X POST "$BASE/api/goal/chat/reset" -H 'Content-Type: application/json' -d '{"seq":1}' >/dev/null && ok "reset endpoint responds" || ng "reset failed"

echo "[4] goal chat send (real claude) — context-aware, isolated per goal"
if command -v claude >/dev/null 2>&1; then
  R=$(curl -s -m 200 -X POST "$BASE/api/goal/chat/send" -H 'Content-Type: application/json' \
       -d '{"seq":1,"text":"Reply with exactly the word PONG and nothing else.","model":"auto"}')
  echo "    assistant: $(echo "$R" | python3 -c 'import sys,json;m=json.load(sys.stdin)["messages"];print(repr(m[-1]["text"][:50]))' 2>/dev/null)"
  echo "$R" | grep -qi pong && ok "goal chat answered" || ng "goal chat did not answer"
  N1=$(curl -s "$BASE/api/goal/chat?seq=1" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["messages"]))')
  N2=$(curl -s "$BASE/api/goal/chat?seq=2" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["messages"]))')
  [ "$N1" = "2" ] && [ "$N2" = "0" ] && ok "goal-1 has history, goal-2 still empty (isolated)" || ng "isolation wrong (g1=$N1 g2=$N2)"
  [ -f "$DATA_DIR/issue/goal-01/chat/chat.json" ] && ok "goal chat persisted to goal-01/chat/chat.json" || ng "chat.json not persisted"
else
  echo "  SKIP: claude CLI not installed"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
