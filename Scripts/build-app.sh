#!/bin/bash
# Assemble a self-contained ConditionManager.app from the SPM release binary.
# Ad-hoc signs the bundle so SMAppService (login item) works locally.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="ConditionManager.app"
BIN_NAME="ConditionManager"
# Captured BEFORE the (multi-minute) compile: sources saved while the build runs are
# NOT in this binary, so /api/update/check must treat them as a pending update. The
# executable's own mtime is stamped at the END of the build and would hide them.
BUILD_START=$(date +%s)

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
