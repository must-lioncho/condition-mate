#!/usr/bin/env bash
# E2E for 날짜 경계 타임존 (issue/2026-09-05-token-view-timezone-directive.md).
#
# 이 검사가 지키는 것:
#   [1] 표시 타임존 기본값이 Asia/Seoul 이다 (빈 데이터 디렉터리).
#   [2] 이미 저장된 "system" 이 1회만 Asia/Seoul 로 옮겨지고 플래그가 디스크에 남는다.
#   [3] 그 뒤에 셀렉터로 `시스템 (맥 설정)` 을 고르면 재시작해도 유지된다.
#       — 이 확인이 빠지면 셀렉터를 죽은 버튼으로 만들어 놓고도 [2] 만으로 통과한다.
#   [5] 경계 구간의 토큰이 표시 타임존 기준 일자에 붙는다.
#   [6] 같은 구간의 활동 초가 '같은 그 날' 행에 붙는다.
#   [7] /history.json 의 "day" 도 같은 경계를 쓰고 계약({day,samples[]})은 그대로다.
#
# [6]이 이번 변경의 핵심이다. 트랜스크립트는 이미 표시 타임존으로 잘렸지만 활동 로그는
# 파일 이름(시스템 로컬)을 곧 날짜로 믿고 있었다. 두 맵은 /tokens.json 의 한 행에서 같은
# `day` 키로 조인되므로, 한 축만 KST 로 옮기면 화면은 안 깨지고 숫자만 조용히 틀린다.
#
# 픽스처 시각은 'KST 로 D일 01:00' 인 한 순간이다. 이 맥은 IST(UTC+5.5)라 같은 순간이
# 시스템 로컬로는 D-1 일 21:30 — 지시서가 지목한 IST 20:30–23:59 구간이다. 스크립트는
# 두 날짜가 실제로 갈리는지를 먼저 확인하고 아니면 멈춘다 (그 맥에서는 검사가 무의미하다).
#
# 픽스처 트랜스크립트만은 격리할 수 없다: AppDelegate.claudeProjectsBase 가
# FileManager.homeDirectoryForCurrentUser 를 쓰는데 이것은 $HOME 환경변수를 보지 않는다
# (getpwuid 를 읽는다 — 이 맥에서 실측 확인). 그래서 실제 ~/.claude/projects 아래에 고유
# 이름의 전용 폴더를 만들고 trap 으로 지운다. 사용자의 기존 세션 파일은 건드리지 않는다.
#
# 구조는 Scripts/e2e-glm-tokens.sh 를 그대로 따른다 — 격리 CM_DATA_DIR, dashboard.port
# 폴링, PASS/FAIL 카운터, trap cleanup. 새 구조를 발명하지 않는다.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="${CM_BIN:-.build/debug/ConditionMate}"
[ -x "$BIN" ] || { echo "build first: swift build"; exit 1; }

# .build 함정 — 저장소 안에 .build '실체'가 생기면 SwiftPM 이 disk I/O error 를 내고도
# exit 0 과 "Build complete!" 를 돌려주며 고친 코드가 없는 바이너리를 남긴다. 이 프로젝트를
# 두 번 태운 자리라, 초록 빌드를 근거로 삼기 전에 링크부터 확인한다.
if [ ! -L .build ]; then
  echo "FAIL: .build is not a symlink (expected -> ~/.cache/cm-swiftpm-build)."
  echo "      A real .build directory here means the binary may not contain your changes."
  exit 1
fi

PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

FIXDIR="$HOME/.claude/projects/cm-tzboundary-e2e-$$"
DATA_A="$(mktemp -d)"; DATA_B="$(mktemp -d)"; ERRLOG="$(mktemp)"
APP_PID=""
cleanup(){
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
  sleep 0.4
  rm -rf "$FIXDIR" "$DATA_A" "$DATA_B" "$ERRLOG"
}
trap cleanup EXIT

# 데이터 디렉터리 하나로 앱을 띄우고, 포트 파일이 아니라 '실제 응답'이 올 때까지 기다린다.
# 포트 파일만 보면 직전 인스턴스가 남긴 낡은 포트를 잡을 수 있다.
boot(){
  local dir="$1"
  rm -f "$dir/dashboard.port"
  CM_DATA_DIR="$dir" CM_DASHBOARD=1 "$BIN" 2>>"$ERRLOG" &
  APP_PID=$!
  PORT=""; BASE=""
  for _ in $(seq 1 100); do
    if [ -f "$dir/dashboard.port" ]; then
      PORT="$(cat "$dir/dashboard.port" 2>/dev/null)"
      if [ -n "$PORT" ] && curl -sf --max-time 5 "http://127.0.0.1:$PORT/api/settings/timezone" >/dev/null 2>&1; then
        BASE="http://127.0.0.1:$PORT"; break
      fi
    fi
    sleep 0.3
  done
  [ -n "$BASE" ] || { echo "FAIL: server did not answer on a port"; tail -20 "$ERRLOG"; exit 1; }
}
halt(){ [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""; sleep 0.4; }
tzset_(){ curl -s --max-time 20 -X POST -H 'content-type: application/json' -d "$1" "$BASE/api/settings/timezone" >/dev/null; }

# ── 픽스처 시각 ────────────────────────────────────────────────────────────────
eval "$(python3 - <<'PY'
import datetime, time
kst = datetime.timezone(datetime.timedelta(hours=9))
d = (datetime.datetime.now(kst) - datetime.timedelta(days=2)).date()
inst = datetime.datetime(d.year, d.month, d.day, 1, 0, 0, tzinfo=kst)   # KST D일 01:00
ep = int(inst.timestamp())
loc = time.localtime(ep)
print(f'FIX_EPOCH={ep}')
print(f'FIX_KST_DAY={inst.strftime("%Y-%m-%d")}')
print(f'FIX_LOCAL_DAY={time.strftime("%Y-%m-%d", loc)}')
print(f'FIX_LOCAL_CLOCK={time.strftime("%H:%M", loc)}')
print(f'FIX_SYS_TZ={time.tzname[loc.tm_isdst]}')
print(f'FIX_ISO={datetime.datetime.fromtimestamp(ep, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")}')
PY
)"
# 모델 이름·앱 이름에 pid 를 넣는다 — 이 맥의 실제 세션과도, 같은 스크립트를 동시에
# 돌리는 다른 실행과도 절대 섞이지 않게 하기 위해서다 (실제로 한 번 겹쳐 두 배로 셌다).
FIX_IN=123000; FIX_OUT=45000; FIX_MODEL="cm-e2e-tz-model-$$"; FIX_APP="cm-e2e-tz-$$"; FIX_ACTIVE=150
echo "fixture instant : epoch=$FIX_EPOCH  ($FIX_ISO)"
echo "  KST 일자      : $FIX_KST_DAY 01:00"
echo "  시스템 로컬   : $FIX_LOCAL_DAY $FIX_LOCAL_CLOCK $FIX_SYS_TZ"
if [ "$FIX_KST_DAY" = "$FIX_LOCAL_DAY" ]; then
  echo "FAIL: 이 맥의 로컬 일자와 KST 일자가 이 순간에 같다 — 두 축을 가를 수 없다."
  exit 1
fi

seed_fixtures(){    # $1 = 데이터 디렉터리
  mkdir -p "$FIXDIR" "$1/activity"
  # 트랜스크립트: 경계 구간에 assistant 줄 하나. 모델 이름을 전용으로 두어 이 맥의 실제
  # 세션들과 절대 섞이지 않게 한다 (day 행의 models 맵에서 이 이름만 골라 본다).
  cat > "$FIXDIR/tz-boundary-session.jsonl" <<EOF
{"type":"user","timestamp":"$FIX_ISO","uuid":"cm-tzb-u1","cwd":"$FIXDIR","message":{"role":"user","content":"tz boundary fixture"}}
{"type":"assistant","timestamp":"$FIX_ISO","uuid":"cm-tzb-a1","requestId":"cm-tzb-req1","cwd":"$FIXDIR","message":{"id":"cm-tzb-msg1","model":"$FIX_MODEL","usage":{"input_tokens":$FIX_IN,"output_tokens":$FIX_OUT,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
  # 활동 샤드 이름은 앱이 짓는 규칙 그대로 '시스템 로컬 일자'다. 지시서가 말한
  # activity-<D-1>.jsonl 이 바로 이 파일이고, 파일 이름을 날짜로 믿으면 KST 행에는
  # 절대 못 붙는 배치다. 즉 이 이름 자체가 "읽는 쪽이 t 로 재버킷하는가"의 시험이다.
  python3 - <<PY > "$1/activity/activity-$FIX_LOCAL_DAY.jsonl"
t = $FIX_EPOCH
for i in range(3):
    print('{"t":%d,"rate":10,"active":50,"phase":"-","bpm":0,"working":true,"key":5,'
          '"mouse":5,"mult":5,"meeting":false,"app":"$FIX_APP","profile":"-","track":"-",'
          '"site":"-","tier":"적극"}' % (t + i * 60))
PY
}

# ── [1] 새 기본값 ─────────────────────────────────────────────────────────────
seed_fixtures "$DATA_A"
boot "$DATA_A"
echo "server up on $BASE (data: $DATA_A)"
echo "[1] 빈 데이터 디렉터리 → 표시 타임존 기본값이 Asia/Seoul"
TZJSON="$(curl -s --max-time 20 "$BASE/api/settings/timezone")"
echo "   $TZJSON"
[ "$TZJSON" = '{"tz":"Asia/Seoul","effective":"Asia/Seoul","label":"KST (UTC+9)"}' ] \
  && ok "GET /api/settings/timezone == {tz:Asia/Seoul, effective:Asia/Seoul, label:KST (UTC+9)}" \
  || ng "새 기본값이 Asia/Seoul 이 아니다"

# ── [4]~[7] 일자 경계 ─────────────────────────────────────────────────────────
echo "[4] 픽스처: 트랜스크립트 1건(in=$FIX_IN) + 활동 샘플 3건(active 합 $FIX_ACTIVE)"
echo "   transcript : $FIXDIR/tz-boundary-session.jsonl"
echo "   activity   : $DATA_A/activity/activity-$FIX_LOCAL_DAY.jsonl"
ok "픽스처를 놓았다 (샤드 이름은 시스템 로컬 일자 $FIX_LOCAL_DAY)"

tzset_ '{"tz":"system"}'
BEFORE="$(curl -s --max-time 300 "$BASE/tokens.json?days=7")"
tzset_ '{"tz":"Asia/Seoul"}'
AFTER="$(curl -s --max-time 300 "$BASE/tokens.json?days=7")"

echo "[5] 경계 구간의 토큰이 KST 일자 행으로 옮겨진다"
python3 - "$BEFORE" "$AFTER" "$FIX_LOCAL_DAY" "$FIX_KST_DAY" "$FIX_MODEL" "$FIX_IN" <<'PY'
import sys, json
before, after, locday, kstday, model, want = sys.argv[1:7]
want = int(want)
def tok(js, day):
    for r in json.loads(js).get('days', []):
        if r['day'] == day:
            return (r.get('models') or {}).get(model, {}).get('in', 0)
    return 0
b_loc, b_kst = tok(before, locday), tok(before, kstday)
a_loc, a_kst = tok(after, locday), tok(after, kstday)
print(f'   BEFORE  tz=system      : {locday} = {b_loc} tok · {kstday} = {b_kst} tok')
print(f'   AFTER   tz=Asia/Seoul  : {locday} = {a_loc} tok · {kstday} = {a_kst} tok')
assert (b_loc, b_kst) == (want, 0), ('before', b_loc, b_kst)
assert (a_loc, a_kst) == (0, want), ('after', a_loc, a_kst)
PY
[ $? -eq 0 ] && ok "픽스처 토큰 $FIX_IN 이 $FIX_LOCAL_DAY → $FIX_KST_DAY 로 이동했다" \
             || ng "토큰의 일자 귀속이 표시 타임존을 따르지 않는다"

echo "[6] 같은 구간의 활동 초가 '같은 그 날' 행에 붙는다 (두 축이 만나는 자리)"
python3 - "$BEFORE" "$AFTER" "$FIX_LOCAL_DAY" "$FIX_KST_DAY" "$FIX_ACTIVE" <<'PY'
import sys, json
before, after, locday, kstday, want = sys.argv[1:6]
want = int(want)
def act(js, day):
    for r in json.loads(js).get('days', []):
        if r['day'] == day:
            return r.get('activeSec')
    return None
b_loc, b_kst = act(before, locday), act(before, kstday)
a_loc, a_kst = act(after, locday), act(after, kstday)
print(f'   BEFORE  tz=system      : activeSec {locday} = {b_loc} · {kstday} = {b_kst}')
print(f'   AFTER   tz=Asia/Seoul  : activeSec {locday} = {a_loc} · {kstday} = {a_kst}')
# tz=system 이면 샤드 이름 일자 == 표시 일자라 옛 코드와 같은 자리에 붙는다.
assert b_loc == want, ('before local', b_loc)
# tz=KST 면 토큰과 같은 날로 따라와야 한다. 안 따라오면 시간효율 배수가 매일 어긋난다.
assert a_kst == want, ('after kst', a_kst)
assert a_loc in (None, 0), ('after local should be empty', a_loc)
PY
[ $? -eq 0 ] && ok "활동 초 ${FIX_ACTIVE}s 가 토큰과 같은 $FIX_KST_DAY 행에 붙는다" \
             || ng "활동 초가 여전히 샤드 파일 이름($FIX_LOCAL_DAY)에 묶여 있다"

echo "[7] /history.json 의 day 도 같은 경계를 쓰고 계약은 그대로다"
curl -s --max-time 120 "$BASE/history.json?days=7" | python3 -c "
import sys, json
ds = json.load(sys.stdin)['days']
assert ds, 'history empty'
assert all(set(d) == {'day','samples'} for d in ds), [set(d) for d in ds]
assert [d['day'] for d in ds] == sorted((d['day'] for d in ds), reverse=True), 'not newest-first'
for d in ds:
    for s in d['samples']:
        assert set(s) == {'t','active','mult','meeting','tier','app'}, set(s)
m = {d['day']: d for d in ds}
hit = [s for s in m.get('$FIX_KST_DAY', {'samples':[]})['samples'] if s['app'] == '$FIX_APP']
assert len(hit) == 3, ('expected 3 fixture samples on $FIX_KST_DAY', len(hit), sorted(m))
stray = [s for s in m.get('$FIX_LOCAL_DAY', {'samples':[]})['samples'] if s['app'] == '$FIX_APP']
assert not stray, ('samples left on the shard-name day', len(stray))
print('   history days:', [d['day'] for d in ds])
print('   $FIX_KST_DAY 의 $FIX_APP 샘플:', len(hit))
" && ok "history.json 이 샘플을 $FIX_KST_DAY 로 내고 {day,samples[{t,active,mult,meeting,tier,app}]} 계약이 유지된다" \
  || ng "history.json 의 day 또는 wire 계약이 깨졌다"
halt

# ── [2] 1회 마이그레이션 ──────────────────────────────────────────────────────
echo "[2] 저장된 cm.timeZone:\"system\" 이 부팅 때 1회 Asia/Seoul 로 옮겨진다"
printf '{"cm.timeZone":"system"}' > "$DATA_B/settings.json"
boot "$DATA_B"
curl -s --max-time 20 "$BASE/api/settings/timezone" | python3 -c "
import sys, json; d = json.load(sys.stdin)
assert d['tz'] == 'Asia/Seoul', d
print('  ', json.dumps(d, ensure_ascii=False))
" && ok "엔드포인트가 Asia/Seoul 을 준다" || ng "마이그레이션이 안 돌았다"
python3 - "$DATA_B/settings.json" <<'PY' && ok "settings.json 에 cm.timeZone=Asia/Seoul · cm.timeZoneKSTMigrated=true 가 남았다" || ng "디스크에 마이그레이션 결과가 없다"
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("cm.timeZone") == "Asia/Seoul", d
assert d.get("cm.timeZoneKSTMigrated") in (True, 1), d
print("   settings.json:", json.dumps({k: v for k, v in d.items() if k.startswith("cm.timeZone")}))
PY

echo "[3] 마이그레이션 뒤에 사람이 다시 고른 \`시스템 (맥 설정)\` 이 재시작을 넘어 유지된다"
tzset_ '{"tz":"system"}'
halt
boot "$DATA_B"
curl -s --max-time 20 "$BASE/api/settings/timezone" | python3 -c "
import sys, json; d = json.load(sys.stdin)
assert d['tz'] == 'system', ('재시작이 사람의 선택을 KST 로 덮었다 — 셀렉터가 죽은 버튼이다', d)
print('  ', json.dumps(d, ensure_ascii=False))
" && ok "재시작 후에도 tz=system 이 유지된다 (셀렉터가 살아 있다)" \
  || ng "마이그레이션이 사람의 선택을 다시 덮어썼다"
halt

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
