#!/usr/bin/env bash
# E2E for GLM(z.ai) 토큰 추적. glm-claude 는 Claude Code 를 z.ai 의 Anthropic 호환
# 엔드포인트로 꺾어 띄우므로 GLM 세션의 트랜스크립트가 ~/.claude/projects 에 그대로
# 섞여 쌓인다. 예전에는 그 폴더에 있으면 무조건 클로드로 귀속해서, GLM 이 쓴 토큰이
# `클로드 기본` 에 묻혀 골라낼 수 없었다 (총합에는 들어가는데 추적은 안 되는 상태).
#
# 이 검사는 실제 HTTP API 를 격리된 데이터 디렉터리의 헤드리스 인스턴스에 물어본다.
# 읽는 트랜스크립트는 사용자의 실제 ~/.claude/projects 이므로 GLM 세션이 하나도 없는
# 맥에서는 실측 항목을 건너뛰고 그 사실을 출력한다.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="${CM_BIN:-.build/debug/ConditionMate}"
[ -x "$BIN" ] || { echo "build first: swift build"; exit 1; }

DATA_DIR="$(mktemp -d)"; ERRLOG="$(mktemp)"
PASS=0; FAIL=0; SKIP=0
cleanup(){ [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null; rm -rf "$DATA_DIR" "$ERRLOG"; }
trap cleanup EXIT
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
sk(){ echo "  SKIP: $1"; SKIP=$((SKIP+1)); }

CM_DATA_DIR="$DATA_DIR" CM_DASHBOARD=1 "$BIN" 2>"$ERRLOG" &
APP_PID=$!
PORT=""
for _ in $(seq 1 60); do
  [ -f "$DATA_DIR/dashboard.port" ] && PORT="$(cat "$DATA_DIR/dashboard.port" 2>/dev/null)"
  [ -n "$PORT" ] && break; sleep 0.3
done
[ -n "$PORT" ] || { echo "FAIL: server did not report a port"; cat "$ERRLOG"; exit 1; }
BASE="http://127.0.0.1:$PORT"
echo "server up on $BASE (data: $DATA_DIR)"

ACCOUNTS="$(curl -s "$BASE/tokens-accounts.json")"
TOKENS="$(curl -s "$BASE/tokens.json?days=90")"

echo "[1] GLM provider 계정이 목록에 등록된다"
echo "$ACCOUNTS" | python3 -c "
import sys,json
a=[x for x in json.load(sys.stdin)['accounts'] if x['provider']=='glm']
assert a, 'no glm account registered'
print('   glm accounts:', ', '.join(x['id']+'='+x['label'] for x in a))
" && ok "tokens-accounts.json 에 glm provider 계정이 있다" || ng "glm 계정이 등록되지 않았다"

echo "[2] ~/.zai/glm-accounts.json 의 라벨이 계정 id 로 들어온다"
if [ -f "$HOME/.zai/glm-accounts.json" ]; then
  python3 - "$ACCOUNTS" <<'PY' && ok "레지스트리 라벨이 전부 glm:<라벨> 로 등록됐다" || ng "레지스트리 라벨 중 빠진 것이 있다"
import json,os,sys
reg=json.load(open(os.path.expanduser("~/.zai/glm-accounts.json")))
want={"glm:"+a["label"] for a in reg.get("accounts",[]) if a.get("label")}
have={a["id"] for a in json.loads(sys.argv[1])["accounts"]}
missing=want-have
assert not missing, f"missing {missing}"
print("   registry labels:", ", ".join(sorted(want)) or "(none)")
PY
else
  sk "~/.zai/glm-accounts.json 이 없다 (GLM 미사용 환경)"
fi

echo "[3] 일별 집계에 providers.glm 이 잡힌다"
GLM_DAYS="$(echo "$TOKENS" | python3 -c "
import sys,json
d=json.load(sys.stdin).get('days',[])
rows=[r for r in d if (r.get('providers') or {}).get('glm',0)>0]
for r in rows: print(r['day'], (r['providers'])['glm'])
")"
if [ -n "$GLM_DAYS" ]; then
  echo "$GLM_DAYS" | sed 's/^/   /'
  ok "providers.glm > 0 인 날이 $(echo "$GLM_DAYS" | wc -l | tr -d ' ')일 있다"
else
  sk "이 맥의 트랜스크립트에 GLM 세션이 없다 — 'glm-claude -p ...' 로 하나 돌리고 다시 실행하라"
fi

echo "[4] GLM 토큰이 클로드 계정이 아니라 GLM 계정에 붙는다"
if [ -n "$GLM_DAYS" ]; then
  echo "$TOKENS" | python3 -c "
import sys,json
bad=[]
for r in json.load(sys.stdin).get('days',[]):
    p=r.get('providers') or {}
    if not p.get('glm'): continue
    accs=r.get('accounts') or {}
    glm_acc=sum(v['tokens'] for k,v in accs.items() if k.startswith('glm:'))
    if glm_acc != p['glm']: bad.append((r['day'],p['glm'],glm_acc))
    # 계정 합은 그날 총량과 같아야 한다 — 어느 쪽으로도 새면 안 된다.
    tot=sum(v['tokens'] for v in accs.values())
    if tot != r['tokens']: bad.append((r['day'],'sum',tot,r['tokens']))
assert not bad, bad
" && ok "glm:* 계정 합 == providers.glm, 그리고 계정 합 == 그날 총량" || ng "계정 귀속이 provider 합과 어긋난다"
else
  sk "GLM 세션이 없어 귀속을 검사할 수 없다"
fi

echo "[5] 세션 한 줄의 provider 가 glm 이고 GLM 계정 뱃지를 단다"
if [ -n "$GLM_DAYS" ]; then
  DAY="$(echo "$GLM_DAYS" | tail -1 | awk '{print $1}')"
  curl -s "$BASE/tokens-sessions.json?day=$DAY" | python3 -c "
import sys,json
ss=json.load(sys.stdin).get('sessions',[])
glm=[s for s in ss if any(m.lower().startswith('glm') for m in (s.get('models') or {}))]
assert glm, 'no glm session on this day'
wrong=[(s['sid'],s['provider'],s['accountLabel']) for s in glm
       if s['provider']!='glm' or not s['account'].startswith('glm:')]
assert not wrong, wrong
for s in glm: print('   ',s['sid'],s['provider'],s['accountLabel'],s['tokens'],list(s['models']))
" && ok "$DAY 의 GLM 세션이 전부 provider=glm · account=glm:*" || ng "GLM 세션이 여전히 클로드로 귀속된다"
else
  sk "GLM 세션이 없어 세션 줄을 검사할 수 없다"
fi

echo "[6] 클로드 세션이 GLM 으로 오염되지 않는다 (회귀)"
echo "$TOKENS" | python3 -c "
import sys,json
for r in json.load(sys.stdin).get('days',[]):
    accs=r.get('accounts') or {}
    p=r.get('providers') or {}
    cl=sum(v['tokens'] for k,v in accs.items() if k.startswith('claude:'))
    assert cl == p.get('claude',0), (r['day'], cl, p.get('claude',0))
" && ok "claude:* 계정 합 == providers.claude (모든 날)" || ng "클로드 귀속이 깨졌다"

echo
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
