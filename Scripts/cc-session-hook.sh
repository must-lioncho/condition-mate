#!/bin/bash
# Claude Code session hook -> ConditionManager dashboard.
#
# Bridges a Claude Code session lifecycle event to the local dashboard so the
# session shows up as a goal whose status tracks real agent activity:
#   start  (SessionStart)      -> create/ensure the goal in 대기 (backlog)
#   active (UserPromptSubmit)  -> 진행 (in_progress); starts the active-time clock
#   wait   (Notification)      -> 응답 대기 (waiting); banks elapsed time and STOPS the
#                                 clock so a human-wait is never counted as active work
#   idle   (Stop)              -> 대기 (backlog); banks the elapsed active time
#   end    (SessionEnd)        -> 완료 (done); banks any final active time
#
# The accumulated active time (진행 windows only) answers "how long did the
# agent actually work" — distinguishing managed runs from idle token burn.
#
# Usage (from .claude/settings.json hooks): cc-session-hook.sh <event>
# Reads the hook payload JSON on stdin; always exits 0 so it never blocks Claude.

event="${1:-start}"
input="$(cat)"

# Extract a top-level string field from the hook JSON without requiring jq.
field() {
  printf '%s' "$input" \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 \
    | sed 's/.*"\([^"]*\)"$/\1/'
}

sid="$(field session_id)"
[ -z "$sid" ] && exit 0

# The data dir mirrors AppPaths.base (CM_DATA_DIR override, else Application Support).
data_dir="${CM_DATA_DIR:-$HOME/Library/Application Support/ConditionManager}"
port_file="$data_dir/dashboard.port"
[ -f "$port_file" ] || exit 0
port="$(tr -dc '0-9' < "$port_file")"
[ -z "$port" ] && exit 0

# Title the goal with Claude Code's own session title (the "aiTitle" it auto-generates
# and writes into the transcript). It does not exist at SessionStart and gets filled in
# / refined as the session runs, so we re-read the latest one on every event. Empty until
# Claude produces it — the server keeps the "Claude 세션 <id>" placeholder until then.
text=""
tpath="$(field transcript_path)"
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  if command -v python3 >/dev/null 2>&1; then
    # Proper JSON parse: handles quotes/escapes/unicode in the title correctly. A
    # manual goal-title-override (written by the dashboard on rename) wins over
    # Claude's auto aiTitle. NB: python3 -c, NOT a heredoc — a here-document inside
    # $(...) fails to parse under macOS's system bash 3.2, which silently broke
    # title extraction entirely (the goal stayed on the "Claude 세션 <id>" placeholder).
    text="$(python3 -c '
import sys, json
title = ""       # Claude auto aiTitle (latest wins)
override = ""    # manual rename from the dashboard (takes precedence)
try:
    for ln in open(sys.argv[1], encoding="utf-8"):
        try:
            o = json.loads(ln)
        except Exception:
            continue
        t = o.get("type")
        if t == "ai-title" and o.get("aiTitle"):
            title = o["aiTitle"]
        elif t == "goal-title-override" and o.get("title"):
            override = o["title"]
except Exception:
    pass
print((override or title).replace(chr(10), " ").strip())
' "$tpath")"
  else
    # Fallback (no python3): grep the last line. A manual goal-title-override wins
    # over Claude's aiTitle; both work for titles without embedded quotes (the
    # overwhelmingly common case).
    text="$(grep '"type":"goal-title-override"' "$tpath" 2>/dev/null | tail -1 \
      | grep -o '"title"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
      | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
    [ -z "$text" ] && text="$(grep '"type":"ai-title"' "$tpath" 2>/dev/null | tail -1 \
      | grep -o '"aiTitle"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
      | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
  fi
fi

# JSON-escape free-text fields (backslash + double-quote) before embedding; aiTitle and
# the path are free text so they can contain quotes. sid/event are safe tokens.
jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
esc_text="$(jesc "$text")"
esc_path="$(jesc "$tpath")"
body="{\"sessionId\":\"$sid\",\"event\":\"$event\",\"text\":\"$esc_text\",\"transcriptPath\":\"$esc_path\"}"

curl -s -m 1 -X POST "http://127.0.0.1:$port/api/session/event" \
  -H 'Content-Type: application/json' \
  -d "$body" >/dev/null 2>&1 || true

exit 0
