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
#
# COEXISTENCE: this dev build is stamped with its OWN bundle id ($DEV_BUNDLE_ID), so it runs
# SIDE BY SIDE with the installed/production ConditionMate.app. DATA IS SHARED: both apps
# use the single ~/.condition-mate store (unified 2026-07-09 — the old per-build .localdata
# isolation made goals/settings diverge and "disappear" when switching apps). Avoid running
# both apps at the same time for long; last-writer-wins on shared files like dashboard.port.
# Without a distinct id the app's
# single-instance dedup (terminateOtherInstances, keyed on bundle id) would force-quit whichever
# copy launched first, so the two could never run at once. The ".dev" suffix still starts with
# ValueTier.ownAppPrefix (matched via hasPrefix), so each app still excludes the other from
# "work" activity. First launch of the dev app prompts for its OWN Automation/Accessibility grant
# (it is a separate app to macOS) — grant once and the stable dev signing identity keeps it.
set -uo pipefail
cd "$(dirname "$0")/.."

DEV_BUNDLE_ID="com.lioncho.conditionmate.dev"   # distinct from prod's com.lioncho.conditionmate
DEV_SIGN_IDENTITY="ConditionMate Dev"           # stable TCC across rebuilds; falls back to ad-hoc

# Dev mode: tell the app not to grab the foreground / auto-pop its window on every rebuild-
# relaunch (AppPaths.isDev). Without this, the watch loop keeps covering the editor. The window
# still opens from the menu bar. NO CM_DATA_DIR here — dev shares the single
# ~/.condition-mate store with the installed app (see COEXISTENCE above). Passed via
# `open --env` below (NOT a plain shell export — `open` hands the app to launchd, which does
# not inherit this shell's environment).
# Set CM_DEV_AUTO_OPEN=1 before running this to auto-open the window after each rebuild
# (for dashboard-UI sessions); it is forwarded through when present.
DEV_ENV=(--env CM_DEV=1)
[ -n "${CM_DEV_AUTO_OPEN:-}" ] && DEV_ENV+=(--env "CM_DEV_AUTO_OPEN=$CM_DEV_AUTO_OPEN")

APP="$PWD/.dev/ConditionMate.app"
BIN="$PWD/.build/debug/ConditionMate"
# Watch only our own Swift sources + the plist (skip the vendored node_modules under Plugins).
# All targets: Sources/ConditionMate + the library modules (Sources/GUI, Sources/WebCLI).
find_sources() {
    find Sources -name '*.swift' -not -path '*/node_modules/*'
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
    cp "$BIN" "$APP/Contents/MacOS/ConditionMate"
    cp Info.plist "$APP/Contents/Info.plist"
    printf 'APPL????' > "$APP/Contents/PkgInfo"
    # Re-stamp the copied plist with the dev identity so this build coexists with prod (see the
    # COEXISTENCE note at the top). Distinct name too, so the menu-bar / Dock / switcher entries
    # are tellable apart.
    PB=/usr/libexec/PlistBuddy
    "$PB" -c "Set :CFBundleIdentifier $DEV_BUNDLE_ID"                 "$APP/Contents/Info.plist" 2>/dev/null || true
    "$PB" -c "Set :CFBundleName ConditionMate Dev"                "$APP/Contents/Info.plist" 2>/dev/null || true
    "$PB" -c "Set :CFBundleDisplayName Condition Mate (Dev)"      "$APP/Contents/Info.plist" 2>/dev/null || true
    # Sign with the stable dev identity when present so the dev app's own TCC grant survives
    # rebuilds; pin -i to the dev bundle id so the designated requirement stays constant. Fall
    # back to ad-hoc (grant will need re-approving after each rebuild in that case).
    if security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_SIGN_IDENTITY"; then
        codesign --force --sign "$DEV_SIGN_IDENTITY" -i "$DEV_BUNDLE_ID" "$APP" >/dev/null 2>&1 || true
    else
        codesign --force --sign - -i "$DEV_BUNDLE_ID" "$APP" >/dev/null 2>&1 || true
    fi
    pkill -f "$APP/Contents/MacOS/ConditionMate" 2>/dev/null || true
    sleep 0.4
    # `open` forwards this shell's environment to the app. A stale CM_DATA_DIR inherited from
    # the shell that started dev-watch (e.g. an old Claude session with the pre-unification
    # .localdata override) would silently flip the dev app to an isolated store — the exact
    # dev/prod data divergence the 2026-07-09 unification removed. Strip it, same as build-app.sh.
    env -u CM_DATA_DIR open "${DEV_ENV[@]}" "$APP"
    echo "==> relaunched $(date +%H:%M:%S) — id=$DEV_BUNDLE_ID data=\$HOME/.condition-mate (shared with prod)"
    echo "    (coexists with the installed app; window stays in the menu bar — click 'Condition Mate (Dev)' to open)"
}

build_and_run
echo "watching Sources (ConditionMate + GUI + WebCLI) … (Ctrl-C to stop)"
if command -v fswatch >/dev/null 2>&1; then
    fswatch -o -l 0.5 Sources Info.plist 2>/dev/null | while read -r _; do
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
