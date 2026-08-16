#!/usr/bin/env bash
# Throwaway test-instance launcher for agents/QA.
#
# WHY: ad-hoc `.build/debug/ConditionMate &` launches piled up on the user's
# screen — each test run left another menu-bar/widget instance behind. Every test
# launch must go through here so exactly ONE test instance exists at a time and it
# is always killable by PID.
#
# Guarantees:
#   - `start` kills any previous test instance first (pidfile + CM_DEV=1 sweep)
#   - the live PID is recorded in .build/test-app.pid
#   - data is isolated in CM_DATA_DIR (never the shared ~/.condition-mate store)
#   - the installed/prod app and dev-watch's .app bundle are NEVER touched:
#     the sweep only matches .build/debug/ConditionMate with CM_DEV=1
#
# Usage:
#   scripts/test-app.sh start [--data <dir>]   build, sign, kill old, launch, print PID+port
#   scripts/test-app.sh stop                   kill the tracked instance (and any stragglers)
#   scripts/test-app.sh status                 show PID / port / uptime
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN=".build/debug/ConditionMate"
PIDFILE=".build/test-app.pid"
LOGFILE=".build/test-app.log"
IDENTITY="ConditionMate Dev"
BUNDLE_ID="com.lioncho.conditionmate"

# Every .build/debug instance carrying CM_DEV=1 is a test launch by definition:
# dev-watch runs the signed .app bundle, prod runs from /Applications.
sweep_pids() {
    local pids=()
    for p in $(pgrep -f "$BIN" 2>/dev/null || true); do
        if ps eww -o command= -p "$p" 2>/dev/null | tr ' ' '\n' | grep -qx "CM_DEV=1"; then
            pids+=("$p")
        fi
    done
    printf '%s\n' "${pids[@]:-}"
}

stop_all() {
    local killed=()
    if [ -f "$PIDFILE" ]; then
        local tracked
        tracked="$(cat "$PIDFILE")"
        if [ -n "$tracked" ] && kill -0 "$tracked" 2>/dev/null; then
            kill "$tracked" 2>/dev/null || true
            killed+=("$tracked")
        fi
        rm -f "$PIDFILE"
    fi
    for p in $(sweep_pids); do
        [ -z "$p" ] && continue
        kill "$p" 2>/dev/null || true
        killed+=("$p")
    done
    if [ ${#killed[@]} -gt 0 ]; then
        sleep 1
        for p in "${killed[@]}"; do
            kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || true
        done
        echo "[test-app] stopped: ${killed[*]}"
    else
        echo "[test-app] nothing to stop"
    fi
}

port_of() {
    lsof -nP -iTCP -sTCP:LISTEN -a -p "$1" 2>/dev/null | awk 'NR>1{split($9,a,":"); print a[2]; exit}'
}

cmd="${1:-start}"
shift || true

case "$cmd" in
stop)
    stop_all
    ;;

status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        pid="$(cat "$PIDFILE")"
        echo "[test-app] running pid=$pid port=$(port_of "$pid") up=$(ps -o etime= -p "$pid" | tr -d ' ')"
    else
        echo "[test-app] not running"
    fi
    strays="$(sweep_pids | tr '\n' ' ' | xargs || true)"
    if [ -n "$strays" ]; then echo "[test-app] CM_DEV instances alive: $strays"; fi
    ;;

start)
    DATA_DIR="${CM_DATA_DIR:-}"
    while [ $# -gt 0 ]; do
        case "$1" in
        --data) DATA_DIR="$2"; shift 2 ;;
        *) break ;;
        esac
    done
    # Isolated by default — a test run must never write the shared store.
    : "${DATA_DIR:=$ROOT/.build/test-data}"
    mkdir -p "$DATA_DIR"

    stop_all

    echo "[test-app] building"
    swift build "$@"

    if security find-identity -p codesigning | grep -q "$IDENTITY"; then
        codesign --force --sign "$IDENTITY" -i "$BUNDLE_ID" "$BIN"
    else
        echo "[test-app] WARNING: signing identity '$IDENTITY' not found" >&2
    fi

    CM_DATA_DIR="$DATA_DIR" CM_DEV=1 CM_SUPPRESS_SESSION_GOAL=1 \
        nohup "$BIN" >"$LOGFILE" 2>&1 &
    pid=$!
    echo "$pid" >"$PIDFILE"

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        port="$(port_of "$pid")"
        [ -n "$port" ] && break
        sleep 0.5
    done
    echo "[test-app] pid=$pid port=${port:-?} data=$DATA_DIR log=$LOGFILE"
    echo "[test-app] stop with: scripts/test-app.sh stop"
    ;;

*)
    echo "usage: scripts/test-app.sh {start|stop|status}" >&2
    exit 2
    ;;
esac
