#!/bin/bash
# Apply an already-built update: quit the running app, swap /Applications, relaunch.
# NO compiling happens here — Scripts/build-app.sh --stage did that in the background
# minutes ago. That is the whole point of the split: pressing 업데이트 costs a copy
# (~2s), not a release build (~40s+).
#
#   Scripts/apply-update.sh          # apply <data>/updates/ConditionManager.app
#
# Invoked by POST /api/update/run when a staged build is ready. Refuses (exit non-zero,
# staged.json untouched) if there is nothing staged, so the caller can fall back to the
# old build-then-install path. Output goes to <data>/update.log.
set -euo pipefail

APP="ConditionManager.app"
BUNDLE_ID="com.lioncho.conditionmanager"
DATA_DIR="${CM_DATA_DIR:-$HOME/.condition-manager}"
STAGE_DIR="$DATA_DIR/updates"
STAGED="$STAGE_DIR/$APP"
STAGED_JSON="$STAGE_DIR/staged.json"
INSTALLED="/Applications/$APP"

if [ ! -d "$STAGED" ]; then
    echo "!! 스테이징된 빌드가 없습니다: $STAGED"; exit 2
fi
# Only ever apply a bundle the stager marked complete. state=building means the copy
# below could catch a bundle mid-swap.
if ! grep -q '"state":"ready"' "$STAGED_JSON" 2>/dev/null; then
    echo "!! 스테이징 상태가 ready 가 아닙니다 — 적용하지 않음"; exit 3
fi
if [ ! -d "$INSTALLED" ]; then
    echo "!! 설치본이 없습니다: $INSTALLED (최초 1회 ./Scripts/build-app.sh --install 필요)"; exit 4
fi

echo "==> Quitting $BUNDLE_ID"
# Normal shutdown path (applicationShouldTerminate), not SIGKILL, so stores flush.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    pgrep -fq "/Applications/$APP/Contents/MacOS/ConditionManager" || break
    sleep 0.3
done

echo "==> Installing staged build"
# Copy to a sibling first, then swap by rename: if this script is killed mid-copy the
# installed app is still the intact old one rather than a half-written bundle.
rm -rf "$INSTALLED.new"
ditto "$STAGED" "$INSTALLED.new"    # ditto preserves the code signature
rm -rf "$INSTALLED.old"
mv "$INSTALLED" "$INSTALLED.old"
mv "$INSTALLED.new" "$INSTALLED"
rm -rf "$INSTALLED.old"

# Strip CM_* overrides before launching: `open` forwards the caller's env, and the app
# is spawned from the dashboard server process, which may carry a dev data dir.
env -u CM_DATA_DIR -u CM_DEV -u CM_DEV_AUTO_OPEN open "$INSTALLED"
echo "==> Relaunched $INSTALLED"

# The staged bundle is now the running one. Drop it so a crash-restarted app never
# re-offers an update it already has; the watcher stages the next one on the next save.
rm -rf "$STAGED"
rm -f "$STAGED_JSON"
