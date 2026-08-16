#!/bin/bash
# Claude Code session hook -> ConditionMate dashboard.
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

# Suppress goal creation for programmatic, headless `claude -p` worker sessions (the app's
# own UI-QA/dedup/search workers and the skill harnesses' producer/reviewer subagents).
# Those aren't user work — they are internal machinery whose "first prompt" is a big fixed
# system prompt, so mirroring them floods the dashboard with echo goals (goal-title-writer
# etc.). The spawner exports CM_SUPPRESS_SESSION_GOAL=1; hooks inherit it, so we can skip
# EVERY event (including start) before any goal — even a placeholder — is ever created.
[ -n "$CM_SUPPRESS_SESSION_GOAL" ] && exit 0

# The data dir mirrors AppPaths.base. Resolution order, so the hook always reaches the
# same store the app writes to:
#   1. CM_DATA_DIR          - explicit override (tests / throwaway runs)
#   2. ~/.condition-mate - the single shared store (dev + prod, unified 2026-07-09)
if [ -n "$CM_DATA_DIR" ]; then
  data_dir="$CM_DATA_DIR"
else
  data_dir="$HOME/.condition-mate"
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

# Defense in depth for the CM_SUPPRESS gate above: even if a worker/subagent session is
# spawned WITHOUT the env var (an ad-hoc `claude --agent … -p`, or an app worker that
# predates the env change), its title is a known fixed system prompt. Drop the event when
# the extracted title starts with one of those signatures so no echo goal is minted. The
# title is truncated to 40 chars upstream, so match on the leading signature only.
case "$text" in
  "# title-writer"*|"# nss-report-reviewer"*|"You turn ONE raw goal"* \
  |"You are an automated UI QA"*|"You are a deduplication judge"* \
  |"You are a semantic search"*|"You are a triage judge"*) exit 0 ;;
esac

# Wait kind (only meaningful for the `wait`/Notification event): split the human-wait into
#   permission - 확인 요청: the agent needs the user to approve a tool. Claude Code's
#                Notification message reads like "needs your permission to use …".
#   decision   - 의사결정 요청: an open question / idle "waiting for your input".
# The dashboard colors these differently in the left rail (blue vs amber). An ended turn
# (idle/Stop) carries no message and is treated as a decision-style wait by the server.
wait_kind=""
if [ "$event" = "wait" ]; then
  msg="$(field message)"
  case "$msg" in
    *permission*|*Permission*|*approve*|*Approve*) wait_kind="permission" ;;
    *) wait_kind="decision" ;;
  esac
fi

# JSON-escape free-text fields (backslash + double-quote) before embedding; aiTitle and
# the path are free text so they can contain quotes. sid/event/wait_kind are safe tokens.
jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
esc_text="$(jesc "$text")"
esc_path="$(jesc "$tpath")"
body="{\"sessionId\":\"$sid\",\"event\":\"$event\",\"text\":\"$esc_text\",\"transcriptPath\":\"$esc_path\",\"waitKind\":\"$wait_kind\"}"

# POST the event to one dashboard instance. curl's exit status is the liveness signal:
# non-zero means the port didn't answer at all (connection refused / timeout) — a dead port.
deliver() {
  curl -s -m 1 -X POST "http://127.0.0.1:$1/api/session/event" \
    -H 'Content-Type: application/json' \
    -d "$body" >/dev/null 2>&1
}

if ! deliver "$port"; then
  # dashboard.port can go stale during a dev-watch relaunch: the dying instance's port-file
  # write can land after the new instance's, so the file points at a dead port. The app
  # self-heals the file within a few seconds, but THIS event fires now — probe the ports
  # ConditionMate actually listens on and deliver to the instance that serves the SAME
  # data dir (checked via GET /api/settings/paths), so a test/dev instance on another
  # store never receives this store's events.
  for p in $(lsof -nP -a -iTCP -sTCP:LISTEN -c ConditionMate 2>/dev/null \
               | grep -o '127\.0\.0\.1:[0-9]*' | sed 's/.*://' | sort -un); do
    [ "$p" = "$port" ] && continue
    owner="$(curl -s -m 1 "http://127.0.0.1:$p/api/settings/paths" 2>/dev/null \
               | grep -o '"data":"[^"]*"' | head -1 | sed 's/^"data":"\(.*\)"$/\1/')"
    [ "$owner" = "$data_dir" ] || continue
    deliver "$p" && break
  done
fi

exit 0
