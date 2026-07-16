#!/bin/bash
# Bug-hunt agent runner -> ConditionManager dashboard.
#
# A LONG-RUNNING (minimum 4h) hunt for FUNCTIONAL / LOGIC bugs — the kind a human
# notices by using the app, e.g. "완료 필터를 꺼도 완료 항목이 계속 보인다". This is
# deliberately DIFFERENT from the qa-agent (Scripts/qa-scan.sh), which only catches UI
# rendering breakage (label wrapping / overflow) on a 10-minute timer. This one reasons
# over the SOURCE to find behavior bugs, and you run it BY HAND when you leave for the day.
#
# The flow, once you launch it:
#   1. Resolve the running app's data dir + dashboard port (for the worker ping).
#   2. Loop until the window (default 4h) elapses. Each ROUND:
#        a. Pick the next focus area (filters, time math, value/ROI, session state, …).
#        b. Hand the app's Sources/ to `claude -p` (Read/Grep/Glob only — no writes, no
#           Bash) and ask it to find ONE concrete, reproducible logic bug in that area
#           that isn't already filed.
#        c. If it finds a real new one, THIS SCRIPT files the goal doc
#           (.claude/issue/goal-NN.md) and bumps the number — claude only writes content.
#        d. Report the round to the 워커 상태 row via /api/worker/ping, with token usage
#           (per-run + cumulative) so the overnight cost is visible.
#        e. Sleep the round interval (default 20분), then go again.
#   3. The agent files goals only — it NEVER fixes anything. You review each goal in the
#      morning and decide whether to fix it (or fire qa-fix-style follow-up yourself).
#
# WHY no fixing / no Bash: this runs unattended overnight. A find-only agent with
# Read/Grep/Glob can't touch your tree, your data, or the running app — safe to leave.
#
# USAGE (run from anywhere; resolves its own paths):
#   Scripts/bug-hunt.sh              # hunt for 4 hours (default), 20분 round cadence
#   Scripts/bug-hunt.sh 6            # hunt for 6 hours
#   BUG_HUNT_ROUND_SEC=900 Scripts/bug-hunt.sh 4   # 15분 cadence
# It keeps running in the foreground; leave the terminal open (or `nohup … &`). To stop
# early: `touch <data_dir>/bug-hunt-stop` or the 꺼짐 toggle on the dashboard.
# Always exits 0.

set -u

WORKER_ID="bug-hunt"

# launchd-style minimal PATH safety, so `claude`, `python3`, `curl` resolve even if run
# from a bare shell.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Resolve the data dir + dashboard port (mirrors qa-scan.sh) -------------------
if [ -n "${CM_DATA_DIR:-}" ]; then
  data_dir="$CM_DATA_DIR"
else
  data_dir="$HOME/.condition-manager"
fi
mkdir -p "$data_dir"
port_file="$data_dir/dashboard.port"
port=""
[ -f "$port_file" ] && port="$(tr -dc '0-9' < "$port_file")"

# Ping helper: POST a run/error report to the worker endpoint (best-effort, 2s cap).
# Args: <status: ok|start|error> <why> <effect>
ping() {
  [ -z "${port:-}" ] && return 0
  jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  curl -s -m 2 -X POST "http://127.0.0.1:$port/api/worker/ping" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$WORKER_ID\",\"status\":\"$1\",\"why\":\"$(jesc "$2")\",\"effect\":\"$(jesc "$3")\"}" \
    >/dev/null 2>&1 || true
}

# --- Window + cadence ------------------------------------------------------------
# Arg 1 = hours (default 4, the user's "최소 4시간"). Round interval from env or the
# bug-hunt-round-sec file (default 1200=20분, floored at 300=5분).
hours="${1:-4}"
case "$hours" in ''|*[!0-9]*) hours=4 ;; esac
[ "$hours" -lt 1 ] && hours=4
window_sec=$(( hours * 3600 ))

round_sec="${BUG_HUNT_ROUND_SEC:-}"
if [ -z "$round_sec" ] && [ -f "$data_dir/bug-hunt-round-sec" ]; then
  round_sec="$(tr -dc '0-9' < "$data_dir/bug-hunt-round-sec")"
fi
case "$round_sec" in ''|*[!0-9]*) round_sec=1200 ;; esac
[ "$round_sec" -lt 300 ] && round_sec=300

disabled_flag="$data_dir/bug-hunt-disabled"
stop_flag="$data_dir/bug-hunt-stop"
rm -f "$stop_flag"   # a stale stop from a prior run must not kill this one

# If turned off via the dashboard toggle, don't start.
if [ -f "$disabled_flag" ]; then
  ping ok "버그 헌트 꺼짐" "꺼짐 상태 — 토글을 켠 뒤 다시 실행하세요(토큰 미사용)"
  exit 0
fi

issue_dir="$PROJECT_DIR/.claude/issue"
mkdir -p "$issue_dir"
token_total_file="$data_dir/bug-hunt-token-total"

# --- Focus areas: rotated round to round so the hunt spreads over the codebase ----
# Each is a concrete behavior surface of THIS app, phrased as what to scrutinize.
FOCI=(
"상태 필터링: 목록·그룹·프리뷰의 상태 필터(대기/진행/완료/취소)와 '완료 컷오프'·'완료 숨김'이 실제로 항목을 거르는지. 예: 완료 필터를 꺼도 완료 항목이 계속 보이는 류의 불일치."
"시간 계산 불변식: 토탈·책상·집중 시간(집중 ⊆ 책상 ⊆ 토탈), trackedSeconds, 대기 시간 적재 여부, 10분 연속성 규칙, 6시간 공백 스팬 절단의 경계 동작."
"가치·토큰·ROI: value/tokens/energy/agents 직렬화와 ROI(가치÷토큰) 계산, 분모 0·음수·결측 처리, 묶음 집계 시 합산 일관성."
"세션 상태 판정: 진행중·응답 대기·입력 필요 매핑(Stop 이벤트 포함), 세션 제목 [seq] 스탬프, 트랜스크립트 누락·중복 처리."
"워커 스케줄·상태: WorkerRegistry의 active 판정(slack=interval*2), recordRun/recordError 카운트, 토글 플래그와 표시 상태의 정합성, 미등록 id ping 무시."
"목표/이슈 관리: seq 번호 매김과 zero-pad, goalDir/legacy goal-NN.md 마이그레이션, 정렬·드래그 배정·스프린트 배정의 경계."
"데이터 영속성: 저장/로드, 원자적 쓰기, 날짜 경계(day rollover)·자정 넘김·타임존, 손상/빈 파일 복구."
"포맷팅 경계값: Formatting.swift의 시간·숫자·퍼센트 표기에서 0·음수·매우 큰 값·반올림 경계의 잘못된 표시."
"동시성: 메인스레드 타이머와 대시보드 네트워크 큐의 공유 상태 접근, 락 범위, 스냅샷 읽기 도중 변경되는 값."
"어뷰징 필터: AbuseFilter의 마우스-only/키-zero 구간·동일 (key,mouse) 반복 판정의 오탐·미탐 경계, 점수·노트 산출."
)
n_foci=${#FOCI[@]}

ts_now(){ date +%s; }
start_epoch="$(ts_now)"

# Interruptible sleep: nap in 10s chunks so a stop/disable toggle is honored fast.
nap() {
  local left="$1"
  while [ "$left" -gt 0 ]; do
    [ -f "$stop_flag" ] && return 1
    [ -f "$disabled_flag" ] && return 1
    local chunk=10; [ "$left" -lt 10 ] && chunk="$left"
    sleep "$chunk"
    left=$(( left - chunk ))
  done
  return 0
}

ping start "버그 헌트 시작 (${hours}시간)" "${hours}시간 동안 ${round_sec}초 주기로 기능·로직 버그 탐색 — goal만 작성, 수정은 안 함"

round=0
filed=0
while : ; do
  now="$(ts_now)"
  elapsed=$(( now - start_epoch ))
  if [ "$elapsed" -ge "$window_sec" ]; then break; fi
  [ -f "$stop_flag" ] && { ping ok "버그 헌트 중단됨" "사용자 중단 — ${round}라운드 진행, goal ${filed}건 작성"; break; }
  [ -f "$disabled_flag" ] && { ping ok "버그 헌트 꺼짐" "토글 꺼짐 — ${round}라운드 진행, goal ${filed}건 작성"; break; }

  round=$(( round + 1 ))
  focus="${FOCI[$(( (round - 1) % n_foci ))]}"

  # Next goal number (max existing goal-NN + 1), and existing titles for dedup.
  next_nn=$(ls "$issue_dir"/goal-*.md 2>/dev/null | sed -E 's#.*/goal-0*([0-9]+)\.md#\1#' | sort -n | tail -1)
  next_nn=$(( ${next_nn:-0} + 1 ))
  nn2=$(printf '%02d' "$next_nn")
  existing_titles="$(for f in "$issue_dir"/goal-*.md; do [ -f "$f" ] && head -n1 "$f"; done)"

  ping start "라운드 ${round} — ${focus%%:*} 점검" "소스 정적 분석으로 신규 로직 버그 탐색 중 (곧 결과)"

  work="$(mktemp -d -t cm-bughunt)"
  result="$work/result.json"
  goalfile="$work/goal-${nn2}.md"

  prompt="You are an automated bug-hunt agent for the ConditionManager macOS app (Swift +
an embedded HTML/JS dashboard). You hunt for ONE real, reproducible FUNCTIONAL / LOGIC
bug — wrong behavior a user would hit — NOT cosmetic UI wrapping (a separate agent owns
that), NOT style nits, NOT speculative 'could be improved' ideas.

The app source is available under these added directories (use Read / Grep / Glob):
  $PROJECT_DIR/Sources
  $issue_dir
Key files: Sources/ConditionManager/Dashboard/DashboardContent.swift (the dashboard
HTML/CSS/JS as Swift string literals — filter logic lives here), AppDelegate.swift
(serialization + HTTP endpoints), Core/ReviewStore.swift, Core/WorkerRegistry.swift,
Core/ActivityLog.swift, Core/IssuePaths.swift, Sources/GUI/Formatting.swift.

FOCUS THIS ROUND:
$focus

A concrete example of the KIND of bug wanted (already known — do NOT refile it, find a
DIFFERENT one): the dashboard 상태 필터 where turning the 완료 filter OFF still leaves
완료 items visible — i.e. a filter/predicate that doesn't actually gate what it claims to.

Existing goal docs already filed (their first heading lines) — do NOT duplicate one that
already describes the same bug:
${existing_titles}

Your job (you do NOT fix anything — you only file a goal):
- Investigate the focus area in the source. Trace the actual control flow / predicate /
  calculation. Find ONE bug you can justify by citing specific code (file + line + the
  exact logic that is wrong) AND describe how a user reproduces it and what they'd see vs.
  what they should see. Hold a high bar: if you are not genuinely confident it is a real
  bug, do NOT invent one.
- If you find NOTHING solid this round, OR the only thing you find is already covered by an
  existing goal above: write ONLY this result JSON to the file $result and stop, writing NO
  goal file: {\"status\":\"ok\",\"effect\":\"이번 라운드 신규 버그 없음 — <한 줄 한글 이유>\"}
- If you find a real NEW bug: create the goal document at EXACTLY this path: $goalfile
  In Korean, matching the existing docs' shape:
    '# goal-${nn2}: <한 줄 제목>' heading, then
    '- 상태: backlog', '- 목적: <왜 고쳐야 하나>', '- 작성일: 2026-06-25',
    '- 관련 코드: <파일:라인 등>',
    '## 1. 증상 / 재현' (구체적 재현 절차 + 기대 동작 대 실제 동작),
    '## 2. 원인 분석' (어느 코드의 어떤 로직이 왜 틀렸는지, 파일·라인 인용),
    '## 3. 수용 기준' (고쳐졌다고 볼 수 있는 관찰 가능한 조건들).
  Then write this result JSON to the file $result:
  {\"status\":\"ok\",\"effect\":\"goal-${nn2} 생성 — <한 줄 한글 요약>\"}
- Keep effect under 80 chars. Write only the file(s) asked; output nothing else."

  # Neutral cwd + --add-dir the two needed subtrees, so claude reads the source but the
  # cwd-based CLAUDE.md auto-load doesn't pull in the large workspace CLAUDE.md every round.
  envelope="$(cd "$work" && claude -p "$prompt" \
    --add-dir "$PROJECT_DIR/Sources" \
    --add-dir "$issue_dir" \
    --allowedTools "Read,Grep,Glob,Write" \
    --permission-mode acceptEdits \
    --output-format json 2>/dev/null)"
  agent_rc=$?

  # The SCRIPT places the goal file: if claude wrote one, move it into .claude/issue.
  moved_goal=""
  if [ -f "$goalfile" ]; then
    mv "$goalfile" "$issue_dir/goal-${nn2}.md" && moved_goal="goal-${nn2}"
  fi

  # --- Token accounting (cumulative tally, own to this worker) ---------------------
  tok_line="$(printf '%s' "$envelope" | python3 -c '
import sys, json
tf = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: print(""); sys.exit()
u = d.get("usage") or {}
inp = int(u.get("input_tokens",0) or 0); out = int(u.get("output_tokens",0) or 0)
cache = int(u.get("cache_read_input_tokens",0) or 0) + int(u.get("cache_creation_input_tokens",0) or 0)
cost = d.get("total_cost_usd"); cost = float(cost) if isinstance(cost,(int,float)) else 0.0
ti=to=0; tc=0.0
try:
    p = json.load(open(tf)); ti=int(p.get("in",0)); to=int(p.get("out",0)); tc=float(p.get("usd",0.0))
except Exception: pass
ti+=inp; to+=out; tc+=cost
try: json.dump({"in":ti,"out":to,"usd":round(tc,4)}, open(tf,"w"))
except Exception: pass
def k(n): return f"{n/1000:.1f}k" if n>=1000 else str(n)
s=f"토큰 in {k(inp)}/out {k(out)}"
if cache: s+=f"·캐시 {k(cache)}"
if cost: s+=f" ${cost:.4f}"
s+=f" · 누적 in {k(ti)}/out {k(to)} ${tc:.2f}"
print(s)
' "$token_total_file" 2>/dev/null)"
  [ -z "$tok_line" ] && tok_line="토큰 사용량 미상(envelope 파싱 실패)"

  # --- Report the round ------------------------------------------------------------
  if [ -s "$result" ]; then
    effect="$(grep -o '"effect"[[:space:]]*:[[:space:]]*"[^"]*"' "$result" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
    [ -z "$effect" ] && effect="버그 점검 완료"
    if [ -n "$moved_goal" ]; then
      filed=$(( filed + 1 ))
      ping ok "라운드 ${round} — 신규 버그 goal 작성" "$effect · $tok_line"
    elif printf '%s' "$effect" | grep -q '생성'; then
      ping error "goal 파일 누락" "claude는 생성 보고했으나 파일이 없음 ($effect) · $tok_line"
    else
      ping ok "라운드 ${round} — 신규 버그 없음" "$effect · $tok_line"
    fi
  else
    ping error "버그 헌트 무응답" "claude -p 결과 없음 (rc=$agent_rc) · $tok_line"
  fi
  rm -rf "$work"

  # Pace to the next round. The window check above guarantees we keep going at least the
  # full duration; nap returns non-zero if a stop/disable toggle fired mid-sleep.
  now="$(ts_now)"; elapsed=$(( now - start_epoch ))
  [ "$elapsed" -ge "$window_sec" ] && break
  remaining=$(( window_sec - elapsed ))
  sleep_for="$round_sec"; [ "$remaining" -lt "$round_sec" ] && sleep_for="$remaining"
  if ! nap "$sleep_for"; then
    [ -f "$stop_flag" ] && ping ok "버그 헌트 중단됨" "사용자 중단 — ${round}라운드 진행, goal ${filed}건 작성"
    [ -f "$disabled_flag" ] && ping ok "버그 헌트 꺼짐" "토글 꺼짐 — ${round}라운드 진행, goal ${filed}건 작성"
    break
  fi
done

rm -f "$stop_flag"
# Final summary ping (unless we already pinged a stop/disable above and broke out — a
# second ok ping is harmless and reflects the final tally).
total_elapsed=$(( $(ts_now) - start_epoch ))
ping ok "버그 헌트 종료 ($(( total_elapsed / 60 ))분)" "${round}라운드 완료 · 신규 goal ${filed}건 작성 — 아침에 검토 후 수정 결정"
exit 0
