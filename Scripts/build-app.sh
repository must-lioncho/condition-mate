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

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP"

echo "==> Done: $(pwd)/$APP"
echo
echo "다음 단계:"
echo "  1) open $APP            # 실행 (메뉴바에 metronome 아이콘)"
echo "  2) /Applications 로 이동 권장 (로그인 항목 안정화)"
echo "  3) 메뉴 → '로그인 시 자동 시작' 체크"
