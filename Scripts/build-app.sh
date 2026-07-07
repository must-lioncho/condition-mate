#!/bin/bash
# Assemble a self-contained ConditionManager.app from the SPM release binary.
# Ad-hoc signs the bundle so SMAppService (login item) works locally.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="ConditionManager.app"
BIN_NAME="ConditionManager"

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
echo
echo "다음 단계:"
echo "  1) open $APP            # 실행 (Dock에 번개 아이콘 + 메뉴바 아이콘)"
echo "  2) /Applications 로 이동 권장 (로그인 항목 안정화)"
echo "  3) 메뉴 → '로그인 시 자동 시작' 체크"
