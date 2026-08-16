#!/bin/bash
# NSS 리포트 (SUT / Supertrust) worker runner -> ConditionMate dashboard.
#
# Runs the /nss-report-daily skill once, unattended, every morning at 09:10 KST
# (fired by launchd; see Scripts/com.condition-mate.nss-daily.plist). The flow:
#   1. Resolve the running app's data dir + dashboard port (mirrors uxui-sitemap.sh).
#   2. Toggle gate: skip when the user turned the worker off (nss-report-disabled,
#      written by the 크론 페이지 꺼짐 button).
#   3. ping "start" so the 워커 row shows activity while the (multi-minute) run is live.
#   4. Run `claude -p` on the skill: fetch on-chain + NSS + Redash settlement figures
#      and rebuild the daily 모니터 리포트 (HTML+PDF) + the 리포트 허브 HTML from the
#      same raw data — no hand-entered values, no stale fallback.
#   5. Verify a FRESH report file was actually produced (not just rc==0), because the
#      skill exits 0 after self-aborting on a fetch failure (e.g. VPN off). Ping ok on
#      real success; ping error + a macOS notification on failure ("중단하고 알림").
#
# ARTIFACT PUBLISH IS NOT DONE HERE. The claude.ai Artifact tool does not exist in a
# headless `claude -p` session (verified 2026-07-13: the run called it 0 times), so the
# "NSS 리포트 허브" artifact on claude.ai is NOT refreshed by this job. This runner only
# regenerates the hub HTML on disk; publishing that HTML to the artifact URL still needs
# an INTERACTIVE Claude session. The ok ping says so plainly so nobody assumes the shared
# artifact auto-updated. (For a truly auto-updating hub, serve the HTML from the app's
# own loopback dashboard instead of the claude.ai artifact.)
#
# PERMISSIONS: this runs claude headless with `--permission-mode acceptEdits` and an
# explicit `--allowedTools` allowlist (Bash + file tools + Skill + WebFetch) — the
# minimum the skill needs to run its python scripts, write report files, and publish
# the artifact with no interactive approver at 09:10. It runs as the logged-in user on
# the local machine against the user's own skill. MCP and any tool outside the list are
# NOT auto-approved. (Scope chosen by the user over --dangerously-skip-permissions.)
#
# Usage: Scripts/nss-report-daily.sh            (run from anywhere; resolves its own paths)
#        Scripts/nss-report-daily.sh --force    (run even if the 꺼짐 flag is set — for testing)
# Always exits 0 so launchd never marks it failed and backs off.

set -u

WORKER_ID="nss-report"

# launchd hands us a minimal PATH; put the common tool locations back (claude lives in
# ~/.local/bin, python3/curl in the homebrew/system dirs).
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Resolve the data dir + dashboard port (mirrors uxui-sitemap.sh) --------------
if [ -n "${CM_DATA_DIR:-}" ]; then
  data_dir="$CM_DATA_DIR"
else
  data_dir="$HOME/.condition-mate"
fi
port_file="$data_dir/dashboard.port"

port=""
if [ -f "$port_file" ]; then
  port="$(tr -cd '0-9' < "$port_file")"
fi

# Ping helper: POST a run/error/start report to the worker endpoint (best-effort, 3s cap).
# Args: <status: ok|error|start> <why> <effect>
ping() {
  [ -z "${port:-}" ] && return 0
  jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  local body
  body="{\"id\":\"$WORKER_ID\",\"status\":\"$1\",\"why\":\"$(jesc "$2")\",\"effect\":\"$(jesc "$3")\"}"
  curl -s -m 3 -X POST "http://127.0.0.1:$port/api/worker/ping" \
    -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1 || true
}

# macOS notification (best-effort). launchd agents run in the user GUI session, so this
# surfaces in Notification Center. Silently ignored if osascript is unavailable.
notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

# --- Toggle gate: the dashboard 크론 row's 꺼짐 writes this flag -------------------
if [ -f "$data_dir/nss-report-disabled" ] && [ "${1:-}" != "--force" ]; then
  exit 0
fi

# --- Freshness probe: newest monitor report file, so we can tell if THIS run produced
# a new one. The skill writes reports/nss-monitor-<date>.html under a per-day task folder,
# so the path is dynamic — track by mtime instead of a fixed path.
newest_report_mtime() {
  find "$data_dir" -name 'nss-monitor-*.html' -type f -print0 2>/dev/null \
    | xargs -0 stat -f '%m' 2>/dev/null | sort -rn | head -1
}
before_mtime="$(newest_report_mtime)"
before_mtime="${before_mtime:-0}"

ping start "매일 09:10 자동 실행" "온체인·NSS·정산 데이터 수집 후 리포트/허브 생성 중… (보통 2~4분)"

# --- Run the skill headless --------------------------------------------------------
# cwd = data dir so the skill's report output lands in the same store the app reads.
# --add-dir grants read/write into the skill's own directory (scripts, templates,
# artifact-url.txt). Approvals are scoped by --allowedTools (comma-separated, mirrors
# bug-hunt.sh) so only these tools run unattended. --output-format json gives us a
# result envelope for logging.
prompt="/nss-report-daily 스킬을 실행해줘. 오늘 자동 실행분으로, 온체인·NSS·Redash 주정산 데이터를 자동으로 가져와서 일일 NSS 모니터 리포트(HTML+PDF)와 리포트 허브 HTML(build_artifact.py)까지 생성해줘. 이 실행은 헤드리스라 claude.ai 아티팩트 발행 도구가 없으니 아티팩트 '발행'은 시도하지 말고 HTML 생성까지만 하면 돼. VPN이 꺼져 있어 데이터 fetch가 실패하면 절대 stale 값이나 추정치로 대체하지 말고 즉시 중단하고 무엇이 실패했는지 명확히 보고해."

skill_dir="$HOME/.claude/skills/nss-report-daily"
envelope="$(cd "$data_dir" && claude -p "$prompt" \
  --add-dir "$skill_dir" \
  --allowedTools "Bash,Read,Write,Edit,Glob,Grep,Skill,WebFetch,Artifact" \
  --permission-mode acceptEdits \
  --output-format json 2>/dev/null)"
agent_rc=$?

after_mtime="$(newest_report_mtime)"
after_mtime="${after_mtime:-0}"

# One-line result summary from the envelope (best-effort; jq optional).
summary=""
if command -v jq >/dev/null 2>&1 && [ -n "$envelope" ]; then
  summary="$(printf '%s' "$envelope" | jq -r '.result // empty' 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
fi

# --- Decide success by ARTIFACT, not exit code -------------------------------------
# The skill can exit 0 after self-aborting on a fetch failure, so rc==0 alone is not
# proof. Require a freshly written monitor report (mtime advanced) as the ground truth.
if [ "$agent_rc" -ne 0 ]; then
  ping error "매일 09:10 자동 실행" "claude 실행 실패 (rc=$agent_rc). VPN·claude 로그인 확인. ${summary}"
  notify "NSS 리포트 실패" "claude 실행 오류(rc=$agent_rc) — VPN/로그인 확인 후 /nss-report-daily 수동 실행"
  exit 0
fi

if [ "$after_mtime" -le "$before_mtime" ]; then
  ping error "매일 09:10 자동 실행" "리포트 미생성 — 데이터 fetch 실패(VPN off) 의심. stale 값으로 대체하지 않고 중단됨. ${summary}"
  notify "NSS 리포트 미생성" "새 리포트가 만들어지지 않았습니다 — VPN 확인 후 /nss-report-daily 수동 실행"
  exit 0
fi

ping ok "매일 09:10 자동 실행" "일일 모니터 리포트·허브 HTML 생성 완료. (claude.ai 아티팩트 발행은 헤드리스 미지원 — 대화형 세션에서 발행 필요) ${summary}"
exit 0
