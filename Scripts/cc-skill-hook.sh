#!/bin/bash
# Claude Code Skill-usage hook -> skill-usage.jsonl (the dashboard's skill history).
#
# Registered on PostToolUse with a `Skill` matcher, so it fires exactly once each time
# ANY skill is invoked — no per-skill instrumentation. The hook payload (stdin JSON)
# carries tool_input.skill (the invoked skill's slug); we append one JSONL line to the
# data dir's skill-usage.jsonl. That file IS the history: the app reads it to show each
# skill's last-used time and use count, plus the chronological history tab.
#
# append-only + one short line per event => the write is atomic (O_APPEND under PIPE_BUF),
# so concurrent sessions never corrupt each other's lines. Works even when the app is not
# running — history is still recorded and shows up the next time the dashboard reads it.
#
# Usage (from .claude/settings.json hooks, PostToolUse matcher "Skill"):
#   cc-skill-hook.sh
# Always exits 0 so it never blocks Claude.

input="$(cat)"

# Data dir — mirrors AppPaths.base and the resolution in cc-session-hook.sh, so the JSONL
# lands in the same store the running app reads:
#   1. CM_DATA_DIR          - explicit override (tests / throwaway runs)
#   2. ~/.condition-manager - the single shared store (dev + prod, unified 2026-07-09)
if [ -n "$CM_DATA_DIR" ]; then
  data_dir="$CM_DATA_DIR"
else
  data_dir="$HOME/.condition-manager"
fi
[ -d "$data_dir" ] || mkdir -p "$data_dir" 2>/dev/null || exit 0

# Extract the invoked skill slug from tool_input.skill. Prefer python3 (correct nested-JSON
# parse); fall back to grep. Empty slug -> nothing to record, so bail.
skill=""
if command -v python3 >/dev/null 2>&1; then
  skill="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input") or {}
    print((ti.get("skill") or "").strip())
except Exception:
    pass
')"
else
  # Fallback: the Skill tool input is {"skill":"<slug>",...}; grab the first "skill":"…".
  skill="$(printf '%s' "$input" | grep -o '"skill"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
    | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
fi
[ -z "$skill" ] && exit 0

# Session id + cwd for the history tab (both optional context). Same field() helper as
# cc-session-hook.sh: a top-level "key":"value" grab, no jq needed.
field() {
  printf '%s' "$input" \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 \
    | sed 's/.*"\([^"]*\)"$/\1/'
}
sid="$(field session_id)"
cwd="$(field cwd)"

epoch="$(date +%s)"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# JSON-escape the free-text fields (skill/cwd can hold quotes/backslashes).
jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
line="{\"epoch\":$epoch,\"ts\":\"$ts\",\"skill\":\"$(jesc "$skill")\",\"session\":\"$(jesc "$sid")\",\"cwd\":\"$(jesc "$cwd")\"}"

printf '%s\n' "$line" >> "$data_dir/skill-usage.jsonl" 2>/dev/null || true
exit 0
