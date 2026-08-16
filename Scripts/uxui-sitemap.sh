#!/bin/bash
# UXUI 관리 worker runner -> ConditionMate dashboard.
#
# Keeps the UXUI sitemap (docs/uxui/sitemap.json, served to the 화면 카탈로그 tab) in
# sync with the CODE: whenever new commits land on the main branch, regenerate the
# sitemap from the sources and install it where the app serves it from. The flow:
#   1. Resolve the running app's data dir + dashboard port (mirrors qa-scan.sh).
#   2. Toggle gate: skip when the user turned the worker off (uxui-sitemap-disabled).
#   3. Commit gate: best-effort `git fetch origin main`, then compare origin/main
#      (falling back to local main, then HEAD) against the last processed commit
#      stamp (<data>/uxui-sitemap-last-commit). Unchanged -> quiet no-op, so the
#      fine launchd tick costs nothing.
#   4. Regenerate: python3 Scripts/uxui-sitemap.py (deterministic source parse).
#   5. Install: copy docs/uxui/sitemap.json -> <data>/screens/sitemap.json (what
#      GET /api/debug/screens/sitemap serves).
#   6. Report the run via POST /api/worker/ping (id "uxui-sitemap") — including the
#      commit range, so the 워커 로그 answers "왜 방금 사이트맵이 바뀌었나".
#
# CADENCE: launchd wakes this script on a fine base tick (300s; see the plist). The
# real work only happens when main actually moved, judged HERE by the commit gate.
#
# Usage: Scripts/uxui-sitemap.sh          (run from anywhere; resolves its own paths)
#        Scripts/uxui-sitemap.sh --force  (regenerate even if main didn't move)
# Always exits 0 so launchd never marks it failed and backs off.

set -u

WORKER_ID="uxui-sitemap"

# launchd hands us a minimal PATH; put the common tool locations back.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Resolve the data dir + dashboard port (mirrors qa-scan.sh) -------------------
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

# --- Toggle gate: the dashboard 크론 row's 꺼짐 writes this flag -------------------
if [ -f "$data_dir/uxui-sitemap-disabled" ]; then
  exit 0
fi

cd "$PROJECT_DIR" || exit 0

# --- Commit gate: only work when main actually moved -------------------------------
# Best-effort fetch (no credentials/offline -> silently use the local view of main).
git fetch --quiet origin main >/dev/null 2>&1 || true
head="$(git rev-parse origin/main 2>/dev/null \
     || git rev-parse main 2>/dev/null \
     || git rev-parse HEAD 2>/dev/null)"
[ -z "$head" ] && exit 0

stamp_file="$data_dir/uxui-sitemap-last-commit"
last=""
[ -f "$stamp_file" ] && last="$(cat "$stamp_file" 2>/dev/null)"
installed="$data_dir/screens/sitemap.json"

if [ "$head" = "$last" ] && [ -f "$installed" ] && [ "${1:-}" != "--force" ]; then
  exit 0   # main didn't move and the sitemap is installed — nothing to do
fi

# --- Regenerate from source + install ----------------------------------------------
gen_out="$(python3 "$SCRIPT_DIR/uxui-sitemap.py" 2>&1)"
if [ $? -ne 0 ]; then
  ping error "main 갱신 감지 (${head:0:8})" "사이트맵 생성 실패: $(printf '%s' "$gen_out" | tail -1)"
  exit 0
fi

mkdir -p "$data_dir/screens"
if ! cp "$PROJECT_DIR/docs/uxui/sitemap.json" "$installed" 2>/dev/null; then
  ping error "main 갱신 감지 (${head:0:8})" "사이트맵 설치 실패: $installed 쓰기 불가"
  exit 0
fi

printf '%s' "$head" > "$stamp_file"

range="${head:0:8}"
[ -n "$last" ] && range="${last:0:8}→${head:0:8}"
summary="$(printf '%s' "$gen_out" | tail -1 | sed 's/^uxui-sitemap: //')"
ping ok "main 갱신 감지 ($range)" "사이트맵 재생성·설치 — $summary"
exit 0
