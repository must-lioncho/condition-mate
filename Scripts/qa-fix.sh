#!/bin/bash
# QA fix agent runner. Fired (detached) by qa-scan.sh right after the inspection agent
# files a goal for UI rendering breakage. It reads that goal and FIXES the source in an
# ISOLATED git worktree (branch qa-fix/goal-NN), builds to verify, then reports via the
# 'qa-fix' worker row. It NEVER touches the user's working tree and NEVER commits/pushes
# — the user reviews the branch's diff and merges.
#
# Isolation matters: the worktree is built from a snapshot of the CURRENT working tree
# (via `git stash create`, including uncommitted edits) so the fix targets the code as it
# actually renders, yet its own checkout + .build can't race the user's active edits.
#
# Usage: qa-fix.sh <NN>            (NN = zero-padded goal number, e.g. 57)
# Always exits 0.

set -u
WORKER_ID="qa-fix"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

nn="${1:-}"
[ -z "$nn" ] && exit 0
goal_src="$PROJECT_DIR/.claude/issue/goal-${nn}.md"
[ -f "$goal_src" ] || exit 0

# --- data dir + port (mirror qa-scan.sh) -----------------------------------------
if [ -n "${CM_DATA_DIR:-}" ]; then data_dir="$CM_DATA_DIR"
else data_dir="$HOME/.condition-manager"; fi
port=""; [ -f "$data_dir/dashboard.port" ] && port="$(tr -dc '0-9' < "$data_dir/dashboard.port")"

ping() {
  [ -z "${port:-}" ] && return 0
  jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  curl -s -m 2 -X POST "http://127.0.0.1:$port/api/worker/ping" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$WORKER_ID\",\"status\":\"$1\",\"why\":\"$(jesc "$2")\",\"effect\":\"$(jesc "$3")\"}" >/dev/null 2>&1 || true
}

# Off switch (the 꺼짐 toggle for the fix worker).
[ -f "$data_dir/qa-fix-disabled" ] && exit 0

ping start "goal-${nn} 자동 수정 시작" "격리 worktree 생성 → 코드 수정 → swift build 검증 (보통 1~3분)"

# --- Isolated worktree from a snapshot of the CURRENT working tree ----------------
# `git stash create` makes a commit of the working tree (tracked edits included) WITHOUT
# touching the stash list or the tree. Empty output => tree clean => use HEAD.
base="$(git -C "$PROJECT_DIR" stash create 2>/dev/null)"
[ -z "$base" ] && base="HEAD"
branch="qa-fix/goal-${nn}"
wt="$(mktemp -d -t cm-qa-fix-${nn})"; rm -rf "$wt"   # worktree add needs a non-existent path
if ! git -C "$PROJECT_DIR" worktree add -b "$branch" "$wt" "$base" >/dev/null 2>&1; then
  branch="qa-fix/goal-${nn}-$(date +%s)"             # branch existed (re-trigger) -> unique
  if ! git -C "$PROJECT_DIR" worktree add -b "$branch" "$wt" "$base" >/dev/null 2>&1; then
    ping error "worktree 생성 실패" "git worktree add 실패 — goal-${nn} 수정 중단"
    exit 0
  fi
fi
# `git stash create` snapshots TRACKED edits only — untracked-but-not-ignored files
# (e.g. brand-new Sources/*.swift) are absent, which breaks the build. Copy them in so
# the worktree compiles. This also brings the just-created goal doc along.
git -C "$PROJECT_DIR" ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
  mkdir -p "$wt/$(dirname "$f")" && cp "$PROJECT_DIR/$f" "$wt/$f" 2>/dev/null
done
mkdir -p "$wt/.claude/issue"; cp "$goal_src" "$wt/.claude/issue/goal-${nn}.md"

goal_content="$(cat "$goal_src")"
result="$wt/.qa-fix-result.json"; rm -f "$result"

prompt="You are an automated UI FIX agent for the ConditionManager macOS app (SwiftUI + an
embedded HTML dashboard). A QA goal describes UI RENDERING BREAKAGE — short labels wrapping
to 2+ lines or overflowing their box. Fix it in THIS working directory, minimally.

GOAL goal-${nn}:
$goal_content

The dashboard UI is generated in Sources/ConditionManager/Dashboard/DashboardContent.swift
(HTML/CSS/JS held as Swift string literals). Wrapping/overflow fixes are CSS/markup, e.g.
'white-space:nowrap' on a label that must stay one line, a wider/min column width, a slightly
smaller font, or padding/letter-spacing tweaks. Keep edits minimal and in the surrounding style.
Do NOT change app logic or unrelated code.

STEPS:
1. Grep DashboardContent.swift for the offending elements named in the goal.
2. Make the minimal CSS/markup edit so each named element stays on one line / within its box.
3. Run 'swift build' to verify it compiles (fix and rebuild if it fails; a few tries max).
4. Write a one-line JSON result to this file: $result (use the Write tool):
   success: {\"status\":\"ok\",\"effect\":\"goal-${nn} 수정 — <무엇을 바꿨는지 한 줄 한글> · 빌드 OK\"}
   failure: {\"status\":\"error\",\"effect\":\"goal-${nn} 수정 실패 — <이유>\"}
   Keep effect under 90 chars. Make the edits + write that file only; output nothing else."

envelope="$(cd "$wt" && claude -p "$prompt" \
  --allowedTools "Read,Edit,Write,Grep,Glob,Bash(swift build:*)" \
  --permission-mode acceptEdits \
  --output-format json 2>/dev/null)"
agent_rc=$?

# --- Token accounting (own cumulative tally, separate from the inspection agent) --
token_total_file="$data_dir/qa-fix-token-total"
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
[ -z "$tok_line" ] && tok_line="토큰 사용량 미상"

# --- Report ----------------------------------------------------------------------
# Did the agent actually change any source? (guards against a phantom success report.)
changed="$(git -C "$wt" status --porcelain -- Sources 2>/dev/null | head -1)"
if [ -s "$result" ]; then
  status="$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$result" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  effect="$(grep -o '"effect"[[:space:]]*:[[:space:]]*"[^"]*"' "$result" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
  [ -z "$status" ] && status="ok"
  [ -z "$effect" ] && effect="수정 완료"
  if [ "$status" = "ok" ] && [ -z "$changed" ]; then
    ping error "수정 변경 없음" "goal-${nn} 성공 보고했으나 소스 변경 없음 · $tok_line"
  else
    ping "$status" "goal-${nn} 자동 수정 (브랜치 $branch)" "$effect · 브랜치 $branch · $tok_line"
  fi
else
  ping error "수정 에이전트 무응답" "claude 결과 없음 (rc=$agent_rc) · $tok_line"
fi

# Leave the worktree + branch for the user to review and merge:
#   git -C "$PROJECT_DIR" diff main..$branch
#   git -C "$PROJECT_DIR" worktree remove "$wt"   (after merging or discarding)
exit 0
