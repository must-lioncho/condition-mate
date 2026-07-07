#!/bin/bash
# Dev auto-reload: watch Swift sources + Info.plist, and on any change rebuild (debug) and
# relaunch the app. Assembles a throwaway .app under .dev/ so the BGM window's WKWebView keeps
# its ATS exception (Info.plist NSAllowsLocalNetworking) — the bare SPM binary does not get it.
#
#   Scripts/dev-watch.sh        # build once, then watch and reload on save
#
# Uses fswatch if installed, otherwise a lightweight mtime poll. Ctrl-C to stop.
# Docker is intentionally NOT used: it runs Linux containers and cannot host a macOS menu-bar
# app / WKWebView, so a local watch-rebuild loop is the right tool.
set -uo pipefail
cd "$(dirname "$0")/.."

# Dev mode: tell the app not to grab the foreground / auto-pop its window on every rebuild-
# relaunch (AppPaths.isDev). Without this, the watch loop keeps covering the editor. The window
# still opens from the menu bar. Passed via `open --env` below (NOT a plain shell export — `open`
# hands the app to launchd, which does not inherit this shell's environment).
# Set CM_DEV_AUTO_OPEN=1 before running this to auto-open the window after each rebuild
# (for dashboard-UI sessions); it is forwarded through when present.
DEV_ENV=(--env CM_DEV=1)
[ -n "${CM_DEV_AUTO_OPEN:-}" ] && DEV_ENV+=(--env "CM_DEV_AUTO_OPEN=$CM_DEV_AUTO_OPEN")

APP="$PWD/.dev/ConditionManager.app"
BIN="$PWD/.build/debug/ConditionManager"
# Watch only our own Swift sources + the plist (skip the vendored node_modules under Plugins).
find_sources() {
    find Sources/ConditionManager -name '*.swift' -not -path '*/node_modules/*'
    echo "Info.plist"
}
newest_mtime() { find_sources | tr '\n' '\0' | xargs -0 stat -f '%m' 2>/dev/null | sort -n | tail -1; }

build_and_run() {
    echo "==> building (debug) $(date +%H:%M:%S)…"
    if ! swift build 2>&1 | grep -E 'error:|Compiling|Build complete' | tail -6; then
        echo "!! build failed — keeping the running instance"; return 1
    fi
    if [ ! -x "$BIN" ]; then echo "!! no debug binary"; return 1; fi
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BIN" "$APP/Contents/MacOS/ConditionManager"
    cp Info.plist "$APP/Contents/Info.plist"
    printf 'APPL????' > "$APP/Contents/PkgInfo"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    pkill -f "$APP/Contents/MacOS/ConditionManager" 2>/dev/null || true
    sleep 0.4
    open "${DEV_ENV[@]}" "$APP"
    echo "==> relaunched $(date +%H:%M:%S) — CM_DEV on (window stays in the menu bar; click to open)"
}

build_and_run
echo "watching Sources/ConditionManager … (Ctrl-C to stop)"
if command -v fswatch >/dev/null 2>&1; then
    fswatch -o -l 0.5 Sources/ConditionManager Info.plist 2>/dev/null | while read -r _; do
        # ignore churn inside vendored deps
        build_and_run
    done
else
    last=$(newest_mtime)
    while sleep 1.5; do
        cur=$(newest_mtime)
        if [ "$cur" != "$last" ]; then last=$cur; sleep 0.4; build_and_run; fi
    done
fi
