#!/bin/bash
# Assemble a self-contained ConditionManager.app from the SPM release binary.
# Ad-hoc signs the bundle so SMAppService (login item) works locally.
#
# Two modes, and the difference is who waits:
#   (default)  build, then quit/swap/relaunch the installed app right now. The user
#              pressing 업데이트 waits out the whole release compile (~40s+).
#   --stage    build and park the finished bundle in <data>/updates/ instead. The
#              running app is NEVER touched. Scripts/autobuild-watch.sh calls this in
#              the background whenever the sources go quiet, so by the time the user
#              presses 업데이트 the build already exists and applying it is a copy
#              (Scripts/apply-update.sh, ~2s). Progress/outcome is written to
#              <data>/updates/staged.json, which is what GET /api/update/check reads.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="ConditionManager.app"
BIN_NAME="ConditionManager"

# --stage: park the build instead of installing it. Everything up to (and including)
# code signing is identical — only the tail differs.
STAGE=0
[ "${1:-}" = "--stage" ] && STAGE=1

# Staging lives in the data dir, NOT the repo: it must survive `git clean`, and the app
# has to find it without being told a repo path. Honour CM_DATA_DIR the same way
# AppPaths does so a test/dev run stages into its own store.
DATA_DIR="${CM_DATA_DIR:-$HOME/.condition-manager}"
STAGE_DIR="$DATA_DIR/updates"
STAGED_JSON="$STAGE_DIR/staged.json"

# staged.json is the whole contract with the app — one small file, last write wins.
#   state    building | ready | failed   (the app shows a button only for ready)
#   buildStart  the staged bundle's CMBuildStart; the app compares it against its own,
#               so "is this newer than me" needs no source scanning and no clock trust.
#   srcAt    newest source mtime this build covers — lets the app tell "ready" from
#            "ready but you've saved more since".
# Written atomically (tmp + mv) because the app polls it every few seconds.
write_staged() {   # state, error
    mkdir -p "$STAGE_DIR"
    local tmp="$STAGED_JSON.tmp.$$"
    printf '{"state":"%s","buildStart":%s,"srcAt":%s,"at":%s,"commit":"%s","error":%s}\n' \
        "$1" "$BUILD_START" "${SRC_AT:-0}" "$(date +%s)" "$(git rev-parse --short HEAD 2>/dev/null || echo '')" \
        "$(printf '%s' "${2:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        > "$tmp"
    mv -f "$tmp" "$STAGED_JSON"
}

# Newest mtime across everything a rebuild depends on — mirrors AppDelegate's
# latestSourceMTime so both sides agree on what "the sources changed" means.
newest_src_mtime() {
    { find Sources -name '*.swift' -not -path '*/node_modules/*' -print0
      printf '%s\0' Package.swift Info.plist Scripts/build-app.sh
    } | xargs -0 stat -f '%m' 2>/dev/null | sort -n | tail -1
}
# Captured BEFORE the (multi-minute) compile: sources saved while the build runs are
# NOT in this binary, so /api/update/check must treat them as a pending update. The
# executable's own mtime is stamped at the END of the build and would hide them.
BUILD_START=$(date +%s)

if [ "$STAGE" = "1" ]; then
    SRC_AT=$(newest_src_mtime)
    # Announce "building" before the compile so the rail can say 준비 중 instead of
    # looking like nothing is happening for 40 seconds. Any failure from here on
    # lands in staged.json as state=failed — quiet for the user, visible on the
    # 시스템 페이지 worker row.
    write_staged building
    trap 'write_staged failed "빌드 실패 (exit $?) — 현재 버전 유지, 상세는 autobuild.log"' ERR
fi

echo "==> Building release binary"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp ".build/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp "Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon (Dock + app switcher). Regenerate the .icns from the master PNG if the
# generator or master is newer, then copy it into the bundle's Resources.
if [ ! -f "Assets/AppIcon.icns" ] || [ "Scripts/gen-icon.swift" -nt "Assets/AppIcon.icns" ] || [ "Assets/AppIcon-1024.png" -nt "Assets/AppIcon.icns" ]; then
    echo "==> Regenerating app icon"
    swift Scripts/gen-icon.swift Assets/AppIcon-1024.png
    ICONSET="Assets/AppIcon.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
                "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
                "512:icon_256x256@2x" "512:icon_512x512"; do
        sz="${spec%%:*}"; name="${spec##*:}"
        sips -z "$sz" "$sz" "Assets/AppIcon-1024.png" --out "$ICONSET/$name.png" >/dev/null
    done
    cp "Assets/AppIcon-1024.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "Assets/AppIcon.icns"
fi
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Stamp the source-tree location into the bundle (before signing — the signature covers
# Info.plist) so the running app can offer in-app updates: the rail 설정 menu shows an
# 업데이트 button when sources are newer than this build (GET /api/update/check), and
# pressing it re-runs this script from CMSourceRoot (POST /api/update/run).
/usr/libexec/PlistBuddy -c "Delete :CMSourceRoot" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CMSourceRoot string $PWD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CMBuildStart" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CMBuildStart string $BUILD_START" "$APP/Contents/Info.plist"

IDENTITY="ConditionManager Dev"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "==> Code signing with '$IDENTITY' (stable Accessibility grant across rebuilds)"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "==> Signing identity '$IDENTITY' not found — falling back to ad-hoc."
    echo "    (Accessibility permission will be lost on every rebuild.)"
    echo "    Run Scripts/setup-signing.sh once to fix this."
    codesign --force --deep --sign - "$APP"
fi

echo "==> Done: $(pwd)/$APP"

# --stage: park it and stop. The running app keeps running; it will notice the new
# staged.json on its next /api/update/check poll and offer the 업데이트 button.
# ditto (not cp) because it preserves the code signature we just applied.
if [ "$STAGE" = "1" ]; then
    trap - ERR
    mkdir -p "$STAGE_DIR"
    rm -rf "$STAGE_DIR/$APP.tmp"
    ditto "$APP" "$STAGE_DIR/$APP.tmp"
    # Swap into place last: a half-copied bundle must never be visible as "ready".
    rm -rf "$STAGE_DIR/$APP"
    mv "$STAGE_DIR/$APP.tmp" "$STAGE_DIR/$APP"
    write_staged ready
    echo "==> Staged: $STAGE_DIR/$APP (앱은 그대로 실행 중 — 업데이트 버튼을 누르면 적용됩니다)"
    exit 0
fi

# In-place update, desktop-auto-updater style: once the app lives in /Applications
# (recommended — stable path for the SMAppService login item), every build quits the
# running instance cleanly, swaps the installed bundle, and relaunches. No manual
# Finder copy. First-time install never happens implicitly — pass --install once.
BUNDLE_ID="com.lioncho.conditionmanager"
INSTALLED="/Applications/$APP"
if [ -d "$INSTALLED" ] || [ "${1:-}" = "--install" ]; then
    echo "==> Updating $INSTALLED"
    # Quit via the normal shutdown path (applicationShouldTerminate), not SIGKILL,
    # so stores flush. Targets prod only — the dev app has the .dev bundle id.
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        # Prod paths only — the dev app (.dev/ConditionManager.app) must not hold the wait.
        pgrep -fq "(/Applications|$PWD)/ConditionManager.app/Contents/MacOS/ConditionManager" || break
        sleep 0.3
    done
    rm -rf "$INSTALLED"
    ditto "$APP" "$INSTALLED"   # ditto preserves the code signature
    # Strip CM_* overrides before launching: `open` forwards the caller's env, and a
    # Claude session shell carries CM_DATA_DIR (settings.local.json), which would flip
    # the prod app into isCustom mode (DEV badge, title stamper disabled).
    env -u CM_DATA_DIR -u CM_DEV -u CM_DEV_AUTO_OPEN open "$INSTALLED"
    echo "==> Relaunched $INSTALLED"
else
    echo
    echo "다음 단계:"
    echo "  1) ./Scripts/build-app.sh --install   # /Applications 에 설치 + 실행 (이후 빌드마다 자동 갱신·재실행)"
    echo "     또는 open $APP                     # 리포에서 바로 실행"
    echo "  2) 메뉴 → '로그인 시 자동 시작' 체크"
fi
