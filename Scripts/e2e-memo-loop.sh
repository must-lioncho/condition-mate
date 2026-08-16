#!/usr/bin/env bash
# E2E for 루프 컷의 메모장 수확 (2026-08-07): 스프린트 완료(릴리즈)가 보드 목표와 함께
# 메모장의 완료 줄을 거둔다 — '@루프: <릴리즈 코드>' 스탬프를 찍고 제목을 릴리즈 기록의
# notes 로 남긴다('노트' 태그의 원천). 지키는 계약:
#   - 완료 목표가 없어도 메모 완료 줄이 있으면 릴리즈 기록이 남는다 (메모만 돈 루프)
#   - 수확은 스탬프 없는 완료 줄만 — 미완료/바틀넥/이미 스탬프된 줄은 건드리지 않는다
#   - 메모 텍스트에 릴리즈 코드가 들여쓴 '@루프: ' 줄로 찍힌다 (판번호 존중, 글 불변)
#   - 목표+메모가 함께 있으면 한 릴리즈에 titles(=session)와 notes(=노트)가 나란히 실린다
#   - /data.json 의 releases[].notes 로 대시보드에 노출된다
# Launches the app headless (CM_DASHBOARD) against an isolated data dir (CM_DATA_DIR).
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

CM_DATA_DIR="$DATA_DIR" CM_DASHBOARD=1 CM_SUPPRESS_SESSION_GOAL=1 "$BIN" 2>"$ERRLOG" &
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
memo(){ curl -s "$BASE/api/memo" | python3 -c 'import sys,json; print(json.load(sys.stdin)["text"])'; }
py(){ state | python3 -c "import sys,json; r=json.load(sys.stdin)['review']; $1"; }

# ── 1. 메모만 돈 루프: 완료 목표 없이 스프린트 완료 → 릴리즈 기록 + notes ──
post /api/memo '{"text":"- [ ] 아직 할 일\n- [x] 메모에서 끝낸 일\n- [!] 막힌 일"}'
post /api/sprint/create '{"goalText":"루프 A","durationKind":"1d"}'
SP=$(py "print(r['sprints'][0]['number'])")
CODE=$(py "print(r['sprints'][0]['code'])")
post /api/sprint/complete "{\"number\":$SP}"

REL_N=$(py "print(len(r['releases']))")
[ "$REL_N" = "1" ] && ok "완료 목표가 없어도 메모 완료 줄로 릴리즈 기록이 남는다" \
                   || ng "릴리즈 기록 수 = $REL_N (want 1)"
NOTES=$(py "print('|'.join(r['releases'][0]['notes']))")
[ "$NOTES" = "메모에서 끝낸 일" ] && ok "notes 에 메모 완료 줄 제목이 실린다" \
                                  || ng "notes = $NOTES"
TITLES=$(py "print(len(r['releases'][0]['titles']))")
[ "$TITLES" = "0" ] && ok "목표 스냅숏(titles)은 비어 있다" || ng "titles = $TITLES"
RCODE=$(py "print(r['releases'][0]['code'])")
[ "$RCODE" = "$CODE" ] && ok "릴리즈 코드 = 스프린트 코드 ($CODE)" || ng "release code = $RCODE (want $CODE)"

M=$(memo)
echo "$M" | grep -q "    @루프: $CODE" && ok "메모에 '@루프: $CODE' 가 들여쓴 줄로 찍힌다" \
                                       || ng "memo text: $M"
echo "$M" | grep -q "^- \[ \] 아직 할 일$" && ok "미완료 줄은 건드리지 않는다" || ng "todo row changed"
STAMPS=$(echo "$M" | grep -c "@루프:")
[ "$STAMPS" = "1" ] && ok "스탬프는 완료 줄에만 1개" || ng "stamp count = $STAMPS"

# ── 2. 목표+메모 함께: 한 릴리즈에 titles 와 notes 가 나란히 ──────────────
post /api/sprint/create '{"goalText":"루프 B","durationKind":"1d"}'
SP2=$(py "print([s for s in r['sprints'] if not s['closed']][0]['number'])")
CODE2=$(py "print([s for s in r['sprints'] if not s['closed']][0]['code'])")
post /api/goal/add '{"text":"세션으로 굴린 목표"}'
GID=$(py "print([g for g in r['goals'] if g['text']=='세션으로 굴린 목표'][0]['id'])")
post /api/goal/sprint "{\"id\":\"$GID\",\"sprint\":$SP2}"
post /api/goal/status "{\"id\":\"$GID\",\"status\":\"done\"}"
post /api/memo "{\"text\":$(memo | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().rstrip("\n")+"\n- [x] 두 번째 루프의 메모"))'),\"base\":2}"
post /api/sprint/complete "{\"number\":$SP2}"

T2=$(py "print('|'.join(r['releases'][0]['titles']))")
N2=$(py "print('|'.join(r['releases'][0]['notes']))")
[ "$T2" = "세션으로 굴린 목표" ] && ok "titles(=session)에 보드 목표가 실린다" || ng "titles = $T2"
[ "$N2" = "두 번째 루프의 메모" ] && ok "notes(=노트)에 새 메모 완료 줄만 실린다 (이전 스탬프 재수확 없음)" \
                                  || ng "notes = $N2"
memo | grep -q "    @루프: $CODE2" && ok "두 번째 릴리즈 코드($CODE2)도 메모에 찍힌다" || ng "no second stamp"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
