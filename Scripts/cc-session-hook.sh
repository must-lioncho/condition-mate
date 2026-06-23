#!/bin/bash
# Claude Code session hook -> ConditionManager dashboard.
#
# Bridges a Claude Code session lifecycle event to the local dashboard so the
# session shows up as a goal whose status tracks real agent activity:
#   start  (SessionStart)      -> create/ensure the goal in 대기 (backlog)
#   active (UserPromptSubmit)  -> 진행 (in_progress); starts the active-time clock
#   wait   (Notification)      -> 응답 대기 (waiting); banks elapsed time and STOPS the
#                                 clock so a human-wait is never counted as active work
#   idle   (Stop)              -> 응답 대기 (waiting); an ended turn is also awaiting the
#                                 human (Claude Code shows it as "입력 필요"), so it shares
#                                 the wait state. Banks elapsed active time, stops the clock.
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

# The data dir mirrors AppPaths.base. Resolution order, so the hook always reaches the
# same store the app writes to:
#   1. CM_DATA_DIR            - explicit override (tests / custom runs)
#   2. CLAUDE_PROJECT_DIR/.localdata - the dev store (dev-run.sh points the app here too),
#                              so a session in this project posts to the running dev app
#   3. ~/Library/Application Support/ConditionManager - the production default
if [ -n "$CM_DATA_DIR" ]; then
  data_dir="$CM_DATA_DIR"
elif [ -n "$CLAUDE_PROJECT_DIR" ] && [ -d "$CLAUDE_PROJECT_DIR/.localdata" ]; then
  data_dir="$CLAUDE_PROJECT_DIR/.localdata"
else
  data_dir="$HOME/Library/Application Support/ConditionManager"
fi
port_file="$data_dir/dashboard.port"
[ -f "$port_file" ] || exit 0
port="$(tr -dc '0-9' < "$port_file")"
[ -z "$port" ] && exit 0

# Title the goal from the session transcript, newest-wins per source, in priority order:
#   goal-title-override (manual rename from the dashboard)   -- always wins
#   ai-title            (Claude's auto-generated rolling title)
#   custom-title        (a pinned title Claude Code attached to the session)
#   first user prompt   (first last-prompt record, truncated) -- fallback that exists once
#                        the session has any prompt, so the goal stops being stuck on the
#                        "Claude 세션 <id>" placeholder when Claude never writes a title.
# Re-read on every event since the higher-priority sources get filled in / refined as the
# session runs. Empty only before the first prompt -- the server keeps the placeholder then.
text=""
tpath="$(field transcript_path)"
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  if command -v python3 >/dev/null 2>&1; then
    # Proper JSON parse: handles quotes/escapes/unicode in the title correctly. Priority
    # is override > ai-title > custom-title > first prompt (see the header comment). NB:
    # python3 -c, NOT a heredoc — a here-document inside $(...) fails to parse under
    # macOS's system bash 3.2, which silently broke title extraction entirely (the goal
    # stayed on the "Claude 세션 <id>" placeholder).
    text="$(python3 -c '
import sys, json
override = ""    # manual rename from the dashboard (always wins)
title = ""       # Claude auto aiTitle (latest wins)
custom = ""      # pinned custom-title Claude Code attached to the session
first = ""       # first user prompt (fallback, present after the first turn)
try:
    for ln in open(sys.argv[1], encoding="utf-8"):
        try:
            o = json.loads(ln)
        except Exception:
            continue
        t = o.get("type")
        if t == "goal-title-override" and o.get("title"):
            override = o["title"]
        elif t == "ai-title" and o.get("aiTitle"):
            title = o["aiTitle"]
        elif t == "custom-title" and o.get("customTitle"):
            custom = o["customTitle"]
        elif t == "last-prompt" and o.get("lastPrompt") and not first:
            first = o["lastPrompt"]
except Exception:
    pass
out = override or title or custom
if not out and first:
    s = " ".join(first.split())
    out = s[:40].rstrip() + ("…" if len(s) > 40 else "")
print(out.replace(chr(10), " ").strip())
' "$tpath")"
  else
    # Fallback (no python3): grep per source in priority order. The last-prompt fallback
    # uses head -1 (the first prompt) and is left untruncated to avoid splitting a
    # multibyte char mid-byte; titles without embedded quotes (the overwhelmingly common
    # case) extract cleanly.
    text="$(grep '"type":"goal-title-override"' "$tpath" 2>/dev/null | tail -1 \
      | grep -o '"title"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
      | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
    [ -z "$text" ] && text="$(grep '"type":"ai-title"' "$tpath" 2>/dev/null | tail -1 \
      | grep -o '"aiTitle"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
      | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
    [ -z "$text" ] && text="$(grep '"type":"custom-title"' "$tpath" 2>/dev/null | tail -1 \
      | grep -o '"customTitle"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
      | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
    [ -z "$text" ] && text="$(grep '"type":"last-prompt"' "$tpath" 2>/dev/null | head -1 \
      | grep -o '"lastPrompt"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
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
