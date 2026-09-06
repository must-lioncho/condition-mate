#!/bin/bash
# Background auto-builder: watch the sources and, once they go QUIET, stage a release
# build so the 업데이트 button is instant when the user finally presses it.
#
#   Scripts/autobuild-watch.sh          # run in the foreground (Ctrl-C to stop)
#   launchd: com.condition-mate.autobuild  (KeepAlive — see the plist next to this)
#
# Why quiet-detection and not build-on-every-save: a release build takes ~40s and pins
# the CPU. Building on each keystroke-save would mean a permanently busy machine and a
# staged bundle that is always one edit stale. Instead: note the change, wait for
# QUIET_SEC of no further edits, then build once. Editing for ten minutes straight costs
# exactly one build, started when you stop.
#
# This NEVER touches the running app — build-app.sh --stage parks the result in
# <data>/updates/ and the app applies it only when the user asks. Failure is silent to
# the user by design (no-user-facing-failure): it lands in staged.json as state=failed
# and on the 시스템 페이지 worker row, and the next successful build clears it.
set -uo pipefail
cd "$(dirname "$0")/.."

QUIET_SEC="${CM_AUTOBUILD_QUIET_SEC:-25}"   # no-edit window before a build starts
POLL_SEC=3

DATA_DIR="${CM_DATA_DIR:-$HOME/.condition-mate}"
LOG="$DATA_DIR/autobuild.log"
DISABLED="$DATA_DIR/autobuild-disabled"     # user off switch (시스템 페이지 토글)
mkdir -p "$DATA_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Report to the app's worker row so this automation is visible and manageable on the
# 시스템 페이지 like every other one. Best-effort: the app may be mid-restart.
ping_app() {   # status, why, effect
    local port; port=$(cat "$DATA_DIR/dashboard.port" 2>/dev/null) || return 0
    [ -n "$port" ] || return 0
    curl -sS -m 2 -X POST "http://127.0.0.1:$port/api/worker/ping" \
        -H 'Content-Type: application/json' \
        --data "$(python3 - "$@" <<'PY'
import json,sys
print(json.dumps({"id":"autobuild","status":sys.argv[1],"why":sys.argv[2],"effect":sys.argv[3]}))
PY
)" >/dev/null 2>&1 || true
}

newest_src_mtime() {
    # .mjs도 센다: 데몬은 이제 번들에 실려 나가는 산출물이라, 데몬만 고친 변경도
    # 리빌드 대상이어야 한다 (예전엔 .swift만 봐서 데몬 수정이 영영 반영되지 않았다).
    { find Sources \( -name '*.swift' -o -name '*.mjs' -o -name 'slack-*.json' \) -not -path '*/node_modules/*' -print0
      printf '%s\0' Package.swift Info.plist Scripts/build-app.sh
    } | xargs -0 stat -f '%m' 2>/dev/null | sort -n | tail -1
}

# The mtime the currently staged build covers — so a restart of this watcher doesn't
# rebuild an identical tree, and so a build that happened while we were down is honoured.
staged_src_at() {
    python3 - "$DATA_DIR/updates/staged.json" <<'PY' 2>/dev/null || echo 0
import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(int(d.get("srcAt", 0)) if d.get("state") in ("ready", "building", "failed") else 0)
except Exception:
    print(0)
PY
}

# The CMBuildStart the INSTALLED app was built at. If it already post-dates every source
# file, the tree is covered and there is nothing to stage — otherwise a watcher started
# right after a manual ./Scripts/build-app.sh would immediately stage a duplicate build and
# light up the 업데이트 button for a no-op.
installed_build_start() {
    /usr/libexec/PlistBuddy -c 'Print :CMBuildStart' \
        "/Applications/ConditionMate.app/Contents/Info.plist" 2>/dev/null || echo 0
}

log "autobuild watcher start (quiet=${QUIET_SEC}s)"
last_built=$(staged_src_at); last_built=${last_built:-0}
if [ "$last_built" -eq 0 ]; then
    installed=$(installed_build_start); installed=${installed:-0}
    src_now=$(newest_src_mtime); src_now=${src_now:-0}
    if [ "$installed" -ge "$src_now" ] && [ "$src_now" -gt 0 ]; then
        last_built=$src_now
        log "installed build already covers the tree (srcAt=$src_now) — idle until the next edit"
    fi
fi

while true; do
    if [ -f "$DISABLED" ]; then sleep 10; continue; fi

    cur=$(newest_src_mtime)
    if [ -z "$cur" ] || [ "$cur" -le "$last_built" ]; then
        # Nothing new. Heartbeat so the worker row reads 동작 중 rather than 유휴 —
        # "watching and there is nothing to do" is a healthy state, not a stalled one.
        ping_app ok "소스 변경 감시" "변경 없음"
        sleep "$POLL_SEC"; continue
    fi

    # Something changed — wait for the edits to stop before spending 40s of CPU.
    log "change detected (srcAt=$cur) — waiting for ${QUIET_SEC}s quiet"
    ping_app start "소스 변경 감지" "편집이 멈추면 빌드 시작 (${QUIET_SEC}초 정적 대기)"
    while true; do
        sleep "$POLL_SEC"
        [ -f "$DISABLED" ] && break
        now=$(date +%s); latest=$(newest_src_mtime)
        if [ "$latest" != "$cur" ]; then cur=$latest; continue; fi     # still editing
        [ $((now - cur)) -ge "$QUIET_SEC" ] && break
    done
    [ -f "$DISABLED" ] && continue

    log "building (srcAt=$cur)"
    ping_app start "정적 상태 도달" "릴리즈 빌드 시작 — 실행 중인 앱은 건드리지 않음"
    if ./Scripts/build-app.sh --stage >> "$LOG" 2>&1; then
        last_built=$cur
        log "staged ok (srcAt=$cur)"
        ping_app ok "빌드 성공" "새 빌드 준비 완료 — 업데이트 버튼을 누르면 적용됩니다"
    else
        # Don't retry the same tree in a loop: mark it built so we only try again after
        # the next edit. build-app.sh already recorded state=failed in staged.json.
        last_built=$cur
        log "build FAILED (srcAt=$cur)"
        ping_app error "빌드 실패" "현재 버전 유지 · 다음 저장 때 다시 시도 — 상세는 autobuild.log"
    fi
done
