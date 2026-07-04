#!/bin/bash
# QA agent runner -> ConditionManager dashboard.
#
# A periodic QA pass that ONLY looks for dashboard UI rendering breakage and, when it
# finds a real one, files a goal doc. It does no fixing. The flow:
#   1. Resolve the running app's data dir + dashboard port.
#   2. Interval gate: skip unless the user-configured period has elapsed (see below).
#   3. Change gate: skip the AI pass unless the UI template actually changed (hash).
#   4. Headless-screenshot the dashboard, hand the PNG to `claude -p` which inspects it
#      for rendering breakage and writes a goal doc (.claude/issue/goal-NN.md) for any
#      NEW issue.
#   5. Report the run to the 워커 상태 row via /api/worker/ping — including the TOKEN
#      USAGE of the AI pass (per-run + cumulative), so cost is visible in the log.
#
# CADENCE / USER-CONFIGURABLE PERIOD:
#   launchd wakes this script on a fine base tick (every 60s; see the plist). The actual
#   period is decided HERE by the interval gate, reading the user's chosen value from
#   <data_dir>/qa-interval-sec (an integer, seconds). Default 600 (10분). To change it,
#   the user edits that one number (or runs Scripts/qa-set-interval.sh <minutes>) — no
#   launchctl reload needed; it takes effect on the next base tick.
#
# The agent itself has no network/Bash access (Read/Write/Glob/Grep only) — THIS
# script owns the HTTP ping, so a healthy run is recorded even if the agent errors.
#
# Usage: Scripts/qa-scan.sh            (run from anywhere; resolves its own paths)
# Always exits 0 so launchd never marks it failed and backs off.

set -u

WORKER_ID="qa-agent"

# launchd hands us a minimal PATH; put the common tool locations back so `claude`,
# `python3`, and `curl` resolve.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# `claude -p` below runs under the project dir, where the project session hooks
# (cc-session-hook.sh) fire. Mark the environment so the hook skips mirroring this internal
# QA session into a dashboard goal — this script reports its own status via /api/worker/ping.
export CM_INTERNAL_WORKER=1

# Project root = two levels up from this script (…/condition-manager/Scripts/qa-scan.sh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Resolve the data dir + dashboard port (mirrors cc-session-hook.sh) ----------
if [ -n "${CM_DATA_DIR:-}" ]; then
  data_dir="$CM_DATA_DIR"
elif [ -d "$PROJECT_DIR/../../.condition-manager" ]; then
  data_dir="$(cd "$PROJECT_DIR/../.." && pwd)/.condition-manager"
elif [ -d "$PROJECT_DIR/.localdata" ]; then
  data_dir="$PROJECT_DIR/.localdata"
else
  data_dir="$HOME/Library/Application Support/ConditionManager"
fi
port_file="$data_dir/dashboard.port"

# Ping helper: POST a run/error report to the worker endpoint (best-effort, 2s cap).
# Args: <status: ok|error> <why> <effect>
ping() {
  [ -z "${port:-}" ] && return 0
  jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  local body
  body="{\"id\":\"$WORKER_ID\",\"status\":\"$1\",\"why\":\"$(jesc "$2")\",\"effect\":\"$(jesc "$3")\"}"
  curl -s -m 2 -X POST "http://127.0.0.1:$port/api/worker/ping" \
    -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1 || true
}

port=""
if [ -f "$port_file" ]; then
  port="$(tr -dc '0-9' < "$port_file")"
fi
if [ -z "$port" ]; then
  # No running dashboard -> nothing to QA. Exit quietly (can't even ping).
  exit 0
fi

url="http://127.0.0.1:$port/"

# --- Force / disabled flags (shared with the dashboard app) -----------------------
# "즉시 실행" forces one pass now, bypassing the disabled + interval + change gates.
# The app either spawns us with QA_FORCE=1, or drops a qa-force-run flag a tick picks
# up. "꺼짐" toggle drops qa-disabled; when present (and not forced) we exit silently —
# no ping, so the row keeps the app-set 꺼짐 state instead of flipping to 유휴.
force=0
[ "${QA_FORCE:-0}" = "1" ] && force=1
if [ -f "$data_dir/qa-force-run" ]; then force=1; rm -f "$data_dir/qa-force-run"; fi
if [ "$force" = "0" ] && [ -f "$data_dir/qa-disabled" ]; then
  exit 0   # turned off by the user
fi

# --- Interval gate: honor the user-configured period -----------------------------
# launchd wakes us every 60s; the real cadence lives here. Read the chosen period
# (seconds) from qa-interval-sec (default 600 = 10분). If not enough time has passed
# since the last actual run, exit silently WITHOUT pinging — so the worker's run
# count / 마지막 실행 reflect the real period, not the 60s base tick.
interval_file="$data_dir/qa-interval-sec"
last_run_file="$data_dir/qa-last-run-epoch"
interval_sec=600
if [ -f "$interval_file" ]; then
  v="$(tr -dc '0-9' < "$interval_file")"
  [ -n "$v" ] && [ "$v" -ge 60 ] && interval_sec="$v"
fi
now_epoch="$(date +%s)"
last_epoch=0
[ -f "$last_run_file" ] && last_epoch="$(tr -dc '0-9' < "$last_run_file")"
[ -z "$last_epoch" ] && last_epoch=0
if [ "$force" = "0" ] && [ "$last_epoch" -gt 0 ]; then
  elapsed=$(( now_epoch - last_epoch ))
  # 30s grace so a 600s period reliably fires on the ~10th 60s tick, not the 11th.
  if [ "$elapsed" -lt $(( interval_sec - 30 )) ]; then
    exit 0   # not due yet
  fi
fi
# Due now: stamp the run time up front so the cadence doesn't drift by claude's runtime.
printf '%s' "$now_epoch" > "$last_run_file" 2>/dev/null || true

# --- Detection: read the dashboard's deterministic self-audit -------------------
# The dashboard measures its OWN layout (every header/button/chip/short-cell whose
# label wraps to 2+ lines or overflows its box) and POSTs the result to /api/qa-audit
# -> qa-audit.json, refreshed on every render plus a ~20s heartbeat. We read it here.
# This sees the WHOLE page at the user's REAL viewport width — no screenshot height
# cutoff, no downscaled-text blindness — and costs ZERO tokens unless something is
# actually broken. A fresh timestamp means the dashboard is open and the measure is
# current; stale means it's closed (nothing to QA right now).
audit_file="$data_dir/qa-audit.json"
audit="$(QA_NOW="$now_epoch" python3 - "$audit_file" <<'PY'
import sys, json, os
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("MISSING\t0\t0\t"); sys.exit()
now_ms = int(os.environ.get("QA_NOW", "0")) * 1000
ts = int(d.get("ts", 0)); width = int(d.get("width", 0)); issues = d.get("issues", []) or []
if now_ms - ts >= 45000:            # >45s since last push -> dashboard closed/stale
    print("STALE\t%d\t%d\t" % (width, len(issues))); sys.exit()
if not issues:
    print("CLEAN\t%d\t0\t" % width); sys.exit()
parts = ["%s %r lines=%s w=%s ovf=%s" % (x.get("tag"), x.get("text"), x.get("lines"),
         x.get("w"), x.get("overflow")) for x in issues[:20]]
print("ISSUES\t%d\t%d\t%s" % (width, len(issues), " | ".join(parts)))
PY
)"
status="$(printf '%s' "$audit" | cut -f1)"
awidth="$(printf '%s' "$audit" | cut -f2)"
acount="$(printf '%s' "$audit" | cut -f3)"
asummary="$(printf '%s' "$audit" | cut -f4-)"

case "$status" in
  MISSING|STALE)
    # No current measurement (dashboard not open). A forced run flags it; a scheduled
    # run skips quietly. Either way: zero tokens.
    if [ "$force" = "1" ]; then
      ping error "대시보드 미개방" "실시간 UI 감사 없음 — 대시보드를 열어 둔 채 다시 시도하세요"
    else
      ping ok "UI 감사 (주기 ${interval_sec}초)" "대시보드 미개방 — 감사 스킵(토큰 미사용)"
    fi
    exit 0 ;;
  CLEAN)
    ping ok "UI 감사 (폭 ${awidth}px)" "렌더링 이상 없음 — 측정 기반 점검(토큰 미사용)"
    exit 0 ;;
esac
# status == ISSUES: real, measured breakage exists. Author a goal for it (unless the
# same issue is already filed). claude runs ONLY in this branch.
ping start "UI 깨짐 감지 — goal 작성" "폭 ${awidth}px에서 ${acount}건 측정 — claude로 goal 작성 중(곧 결과)"

# --- Author the goal via claude -------------------------------------------------
# The SCRIPT owns file placement and numbering; claude only WRITES content into a
# throwaway working dir. This (a) keeps claude in a neutral cwd with no project access,
# so it never auto-loads the workspace's large CLAUDE.md (the old token/cache hog), and
# (b) makes the goal file land reliably — the script moves it into .claude/issue itself.
issue_dir="$PROJECT_DIR/.claude/issue"
# Next number = max existing goal-NN + 1, zero-padded to 2.
next_nn=$(ls "$issue_dir"/goal-*.md 2>/dev/null | sed -E 's#.*/goal-0*([0-9]+)\.md#\1#' | sort -n | tail -1)
next_nn=$(( ${next_nn:-0} + 1 ))
nn2=$(printf '%02d' "$next_nn")
# Existing titles (first heading line of each doc) so claude can skip a duplicate.
existing_titles="$(for f in "$issue_dir"/goal-*.md; do [ -f "$f" ] && head -n1 "$f"; done)"

work="$(mktemp -d -t cm-qa-work)"
result="$work/result.json"
goalfile="$work/goal-${nn2}.md"

prompt="You are an automated UI QA pass for the ConditionManager dashboard. A deterministic
DOM audit (pixel-measured in a REAL browser at viewport width ${awidth}px) found these
elements whose short label WRAPS to 2+ lines, or OVERFLOWS its box — i.e. UI rendering
breakage from font size / column width:

${asummary}

Each entry is: <tag> '<text>' lines=<rendered line count> w=<px width> ovf=<overflow>.
A short label with lines>=2, or ovf=True, is visually broken.

Existing goal docs already filed (their first heading lines) — do NOT duplicate one that
already describes this same UI wrapping/overflow breakage:
${existing_titles}

Your ONLY job (you do NOT fix anything):
- If an existing goal above already covers this breakage: write ONLY the result JSON
  {\"status\":\"ok\",\"effect\":\"깨짐 발견했으나 기존 goal로 커버됨\"} to the file $result and stop.
- Otherwise: create the goal document at EXACTLY this path: $goalfile
  Korean, same shape as the existing docs: a '# goal-${nn2}: <title>' heading, then
  '상태'(backlog), '목적', '작성일'(2026-06-25), '## 1. 증상' (list the specific elements
  above and that they wrap/overflow at about ${awidth}px width), and '## 2. 수용 기준'
  (each listed element renders on one line / within its box at common widths).
  Then write the result JSON {\"status\":\"ok\",\"effect\":\"goal-${nn2} 생성 — <한 줄 한글 요약>\"}
  to the file $result.
Keep effect under 80 chars. Write the two files only; output nothing else."

# Capture the result ENVELOPE (--output-format json) for token usage + cost. cwd is the
# throwaway dir; claude needs no project access, so no --add-dir (avoids loading CLAUDE.md).
envelope="$(cd "$work" && claude -p "$prompt" \
  --allowedTools "Read,Write" \
  --permission-mode acceptEdits \
  --output-format json 2>/dev/null)"
agent_rc=$?

# The script places the file: if claude wrote the goal doc, move it into .claude/issue.
moved_goal=""
if [ -f "$goalfile" ]; then
  mv "$goalfile" "$issue_dir/goal-${nn2}.md" && moved_goal="goal-${nn2}"
fi

# --- Token accounting ------------------------------------------------------------
# Parse this run's tokens/cost from the envelope and fold them into a cumulative
# tally kept in qa-token-total (in/out tokens + USD). `tok_line` is a compact human
# string appended to the worker log effect.
token_total_file="$data_dir/qa-token-total"
tok_line="$(printf '%s' "$envelope" | python3 -c '
import sys, json, os
total_file = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit()
u = d.get("usage") or {}
inp = int(u.get("input_tokens", 0) or 0)
out = int(u.get("output_tokens", 0) or 0)
cache = int(u.get("cache_read_input_tokens", 0) or 0) + int(u.get("cache_creation_input_tokens", 0) or 0)
cost = d.get("total_cost_usd")
cost = float(cost) if isinstance(cost, (int, float)) else 0.0
# Fold into the running totals.
ti = to = 0; tc = 0.0
try:
    with open(total_file) as f:
        prev = json.load(f)
    ti = int(prev.get("in", 0)); to = int(prev.get("out", 0)); tc = float(prev.get("usd", 0.0))
except Exception:
    pass
ti += inp; to += out; tc += cost
try:
    with open(total_file, "w") as f:
        json.dump({"in": ti, "out": to, "usd": round(tc, 4)}, f)
except Exception:
    pass
def k(n):
    return f"{n/1000:.1f}k" if n >= 1000 else str(n)
s = f"토큰 in {k(inp)}/out {k(out)}"
if cache: s += f"·캐시 {k(cache)}"
if cost:  s += f" ${cost:.4f}"
s += f" · 누적 in {k(ti)}/out {k(to)} ${tc:.2f}"
print(s)
' "$token_total_file" 2>/dev/null)"
[ -z "$tok_line" ] && tok_line="토큰 사용량 미상(envelope 파싱 실패)"

# --- Report the run --------------------------------------------------------------
if [ -s "$result" ]; then
  status="$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$result" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  effect="$(grep -o '"effect"[[:space:]]*:[[:space:]]*"[^"]*"' "$result" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
  [ -z "$status" ] && status="ok"
  [ -z "$effect" ] && effect="QA 점검 완료"
  # Cross-check claude's claim against what actually landed on disk. If a goal file was
  # moved into place, prefer a trustworthy effect naming it; if claude claimed creation
  # but no file landed, flag it rather than logging a phantom goal.
  if [ -n "$moved_goal" ]; then
    # The agent's effect already names the goal ("goal-NN 생성 — …"); log it as-is.
    ping ok "UI 깨짐 감지 후 goal 작성" "$effect · $tok_line"
    # HOOK: a new goal was filed -> fire the QA fix agent for it (detached; it reports
    # via its own 'qa-fix' worker). Skipped if the fix worker is toggled off.
    if [ ! -f "$data_dir/qa-fix-disabled" ] && [ -x "$SCRIPT_DIR/qa-fix.sh" ]; then
      CM_DATA_DIR="$data_dir" nohup "$SCRIPT_DIR/qa-fix.sh" "$nn2" >/dev/null 2>&1 &
    fi
  elif printf '%s' "$effect" | grep -q '생성'; then
    ping error "goal 파일 누락" "claude는 생성 보고했으나 파일이 없음 ($effect) · $tok_line"
  else
    ping "$status" "UI 깨짐 감지 (기존 goal로 커버)" "$effect · $tok_line"
  fi
else
  # No status file, but the AI pass may still have burned tokens -> log them anyway.
  ping error "QA 에이전트 무응답" "claude -p 결과 없음 (rc=$agent_rc) · $tok_line — 로그 확인"
fi

rm -rf "$work"
exit 0
