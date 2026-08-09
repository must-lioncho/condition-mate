#!/bin/bash
# Archive "ghost" session goals — the ones a `start`-only Claude session minted.
#
# A ghost is a session-mirrored goal that satisfies ALL of:
#   - its title is still the placeholder  "Claude 세션 <sessionId 앞 8자>"
#   - no transcript exists for its session id anywhere under ~/.claude/projects
#   - trackedSeconds == 0  (no turn was ever worked)
#   - not already archived
# i.e. the session fired SessionStart, wrote nothing, and ended. It can never be
# titled or timed, so it is pure board noise.
#
# ReviewStore now mints session goals on the first prompt (`active`) instead of on
# `start`, so no new ghosts appear — this only clears the backlog of old ones.
#
# Archiving is REVERSIBLE (보관 해제 in the 아카이브 view) and goes through the app's
# API, never a direct goals.json write.
#
# Usage:
#   Scripts/cleanup-ghost-session-goals.sh           # dry run — list what would be archived
#   Scripts/cleanup-ghost-session-goals.sh --apply   # actually archive them

set -euo pipefail
apply=""
[ "${1:-}" = "--apply" ] && apply="1"

data_dir="${CM_DATA_DIR:-$HOME/.condition-manager}"
port_file="$data_dir/dashboard.port"
[ -f "$port_file" ] || { echo "dashboard.port 없음 — 앱이 실행 중인지 확인하세요: $port_file"; exit 1; }
port="$(tr -dc '0-9' < "$port_file")"

APPLY="$apply" GOALS="$data_dir/review/goals.json" PORT="$port" python3 - <<'PY'
import json, os, subprocess, sys

goals_path = os.environ["GOALS"]
port = os.environ["PORT"]
apply = bool(os.environ.get("APPLY"))
projects = os.path.expanduser("~/.claude/projects")

raw = json.load(open(goals_path, encoding="utf-8"))
goals = raw if isinstance(raw, list) else raw.get("goals", [])

dirs = [os.path.join(projects, d) for d in os.listdir(projects)] if os.path.isdir(projects) else []
def has_transcript(sid):
    return any(os.path.exists(os.path.join(d, sid + ".jsonl")) for d in dirs)

ghosts = []
for g in goals:
    sid = (g.get("sessionId") or "").strip()
    if not sid or g.get("archived"):
        continue
    if g.get("text") != "Claude 세션 " + sid[:8]:
        continue
    if (g.get("trackedSeconds") or 0) > 0:
        continue
    if has_transcript(sid):
        continue                      # repairable by the title-repair worker — leave it
    ghosts.append(g)

print(f"유령 세션 목표 {len(ghosts)}개 (전체 {len(goals)}개 중)")
for g in sorted(ghosts, key=lambda x: x.get("seq", 0)):
    print(f"  goal-{g.get('seq')}  {g.get('text')}  [{g.get('status')}]")

if not ghosts:
    sys.exit(0)
if not apply:
    print("\n드라이런입니다. 실제로 보관하려면 --apply 를 붙여 다시 실행하세요.")
    sys.exit(0)

ok = 0
for g in ghosts:
    body = json.dumps({"id": g["id"], "archived": True})
    r = subprocess.run(["curl", "-s", "-m", "5", "-X", "POST",
                        f"http://127.0.0.1:{port}/api/goal/archive",
                        "-H", "Content-Type: application/json", "-d", body],
                       capture_output=True)
    if r.returncode == 0:
        ok += 1
print(f"\n보관 완료: {ok}/{len(ghosts)} (되돌리려면 대시보드 아카이브 뷰에서 보관 해제)")
PY
