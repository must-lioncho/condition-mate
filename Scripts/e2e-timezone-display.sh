#!/usr/bin/env bash
# E2E for 시간 표시 — 저장은 UTC, 화면은 설정한 타임존 (EP-21).
#
# 왜 이 검사가 있는가 (2026-09-06). 이슈 화면의 세션 줄이 이렇게 찍혀 있었다:
#   `세션 97cc3cc2 · 2026-09-06 07:31 · 사람 말 2 번 · 쓴 파일 3 개`
# 그 세션은 KST 16:31 에 시작했다. 07:31 은 UTC 다. 원인은 하드코딩된 타임존이 아니라
# **변환을 아예 안 한 것**이었다 — 저장된 ISO 문자열을 `.replace('T',' ').slice(0,16)` 으로
# 잘라서 그대로 찍었다. 자르기는 변환이 아니다.
#
# 여기는 살아 있는 서버 축만 본다 — 설정을 바꾸면 페이지가 새 `window.CM_TZ` 를 주입하는가,
# 그리고 그 페이지가 변환 코드를 싣고 나가는가. 변환 값 자체(한국 16:31 · 인도 13:01)의
# 판정은 `.e2e/timezone.test.js` 가 진짜 CMTimeFilter 와 진짜 sesHead 를 돌려서 한다.
#
# 구조는 Scripts/e2e-timezone-boundary.sh 를 따른다 — 격리 CM_DATA_DIR, dashboard.port 폴링,
# PASS/FAIL 카운터, trap cleanup. 새 구조를 발명하지 않는다.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=".build/debug/ConditionMate"
[ -L .build ] || { echo "FAIL: .build 가 심볼릭 링크가 아니다"; exit 1; }
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL: $1  [$2]"; FAIL=$((FAIL+1)); }
DATA="$(mktemp -d)"; PID=""
cleanup(){ [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$DATA"; }
trap cleanup EXIT
CM_DATA_DIR="$DATA" CM_HEADLESS=1 "$BIN" >/dev/null 2>&1 &
PID=$!
PORT=""
for _ in $(seq 1 60); do
  PORT="$(cat "$DATA/dashboard.port" 2>/dev/null)"
  [ -n "$PORT" ] && curl -sf "http://127.0.0.1:$PORT/api/settings/timezone" >/dev/null && break
  PORT=""; sleep 0.5
done
[ -n "$PORT" ] || { echo "FAIL: 서버가 안 떴다"; exit 1; }
echo "server up on 127.0.0.1:$PORT (data=$DATA)"
PAGE="$DATA/issues.html"

setz(){ curl -sf -X POST "http://127.0.0.1:$PORT/api/settings/timezone" \
          -H 'Content-Type: application/json' -d "{\"tz\":\"$1\"}" >/dev/null
        curl -sf "http://127.0.0.1:$PORT/issues" -o "$PAGE"; }
inj(){ grep -o "window\.CM_TZ=[^;]*" "$PAGE" | head -1; }
has(){ grep -qF "$1" "$PAGE"; }

for step in "1|Asia/Seoul|한국(UTC+9)" "2|Asia/Kolkata|인도(UTC+05:30) 로 변경" "3|Asia/Seoul|한국으로 되돌림" "4|Asia/Kolkata|다시 인도"; do
  IFS='|' read -r n z desc <<<"$step"
  setz "$z"
  G="$(inj)"; API="$(curl -sf "http://127.0.0.1:$PORT/api/settings/timezone")"
  echo "[$n] $desc"
  echo "    API      = $API"
  echo "    /issues  = $G"
  [ "$G" = "window.CM_TZ='$z'" ] && ok "설정이 /issues 의 CM_TZ 에 반영된다 ($z)" || ng "CM_TZ 반영" "$G"
done

echo "[5] 페이지가 변환 코드를 싣고 나간다 (마지막 상태: 인도)"
has "function isoDisp(v, len, sep)"      && ok "CMTimeFilter.isoDisp 가 실려 있다"      || ng "isoDisp 미탑재" "-"
has "esc(tdisp(S.startedAt,16))"         && ok "세션 줄이 tdisp 를 거친다"              || ng "세션 줄" "-"
# 주의: CMTimeFilter 의 주석이 회귀 모양을 글로 적고 있어서, 문자열만 찾으면 주석에 걸린다.
# 실제 코드 모양(옛 표현식)을 찾는다.
has "esc(String(S.startedAt||'').replace"  && ng "세션 줄에 옛 자르기가 남아 있다" "-" || ok "세션 줄에 옛 자르기 코드가 없다"
has "esc(String(t.at||'').replace"         && ng "턴 줄에 옛 자르기가 남아 있다" "-"   || ok "턴 줄에 옛 자르기 코드가 없다"
has "esc(String(S.lastAt||'').replace"     && ng "보고 줄에 옛 자르기가 남아 있다" "-" || ok "보고 줄에 옛 자르기 코드가 없다"
has "['Asia/Kolkata','IST (UTC+5:30)']"  && ok "설정 셀렉터에 인도 옵션이 있다"         || ng "셀렉터에 인도 없음" "-"
echo "    페이지 크기 = $(wc -c < "$PAGE") bytes"

echo; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
