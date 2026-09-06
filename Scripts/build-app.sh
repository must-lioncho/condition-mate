#!/bin/bash
# Assemble a self-contained ConditionMate.app from the SPM release binary.
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
APP="ConditionMate.app"
BIN_NAME="ConditionMate"

# --stage: park the build instead of installing it. Everything up to (and including)
# code signing is identical — only the tail differs.
STAGE=0
[ "${1:-}" = "--stage" ] && STAGE=1

# Staging lives in the data dir, NOT the repo: it must survive `git clean`, and the app
# has to find it without being told a repo path. Honour CM_DATA_DIR the same way
# AppPaths does so a test/dev run stages into its own store.
DATA_DIR="${CM_DATA_DIR:-$HOME/.condition-mate}"
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
    # .mjs도 센다: 데몬은 이제 번들에 실려 나가는 산출물이라, 데몬만 고친 변경도
    # 리빌드 대상이어야 한다 (예전엔 .swift만 봐서 데몬 수정이 영영 반영되지 않았다).
    { find Sources \( -name '*.swift' -o -name '*.mjs' -o -name 'slack-*.json' \) -not -path '*/node_modules/*' -print0
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
swift build -c release || true

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp ".build/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp ".build/release/NotionKeychainRegister" "$APP/Contents/Resources/NotionKeychainRegister"
chmod 700 "$APP/Contents/Resources/NotionKeychainRegister"
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
# Slack 번역 데몬을 번들 안으로. 이 한 줄이 없던 동안 launchd는 개발 작업트리의
# .mjs를 직접 가리켰고, 레포를 옮기자 운영 데몬이 즉사했다 (2026-08-21, 19시간
# 무수집). 번들에 넣어야 /Applications/ConditionMate.app/Contents/Resources/ 라는
# 업데이트에도 안 변하는 경로가 생기고, 개발 트리와 운영이 완전히 분리된다.
# plist를 그 경로로 맞추는 것은 앱이 한다 (Sources/Plugins/Slack/SlackDaemonInstall.swift).
cp "Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs" "$APP/Contents/Resources/slack-eyes-daemon.mjs"
chmod +x "$APP/Contents/Resources/slack-eyes-daemon.mjs"
cp "Sources/Plugins/Slack/Daemon/slack-reply-policy.json" "$APP/Contents/Resources/slack-reply-policy.json"
# media-extract.mjs는 데몬이 런타임에 ./media-extract.mjs로 동적 import하는 동반 모듈이다.
# 이 줄이 없으면 데몬 스크립트만 번들에 실리고 이 파일은 안 실려서, 번들 안에서는
# import가 항상 실패해 "media-extract 없음" 폴백으로 조용히 저하된다 (2026-08-28 QA 발견).
cp "Sources/Plugins/Slack/Daemon/media-extract.mjs" "$APP/Contents/Resources/media-extract.mjs"
# answer-context.mjs도 같은 동적 import 동반 모듈이다 (선응답의 용어집·문서·리서치·
# 다른 스레드 레이어). 빠뜨리면 데몬은 뜨지만 선응답이 조용히 예전 수준(스레드+Jira)으로
# 돌아간다 — 코드가 아니라 배치 때문에 기능이 사라지는 바로 그 실패 모드다.
cp "Sources/Plugins/Slack/Daemon/answer-context.mjs" "$APP/Contents/Resources/answer-context.mjs"
cp "Sources/Plugins/Slack/Daemon/alignment-engine.mjs" "$APP/Contents/Resources/alignment-engine.mjs"
cp "Sources/Plugins/Slack/Daemon/slack-permission-policy.json" "$APP/Contents/Resources/slack-permission-policy.json"
cp "Sources/Plugins/Slack/Daemon/slack-glossary.json" "$APP/Contents/Resources/slack-glossary.json"
# emoji-layer.mjs 도 같은 동적 import 동반 모듈이다 (닫는 말에 글 대신 리액션 하나로
# 답하는 레이어). 빠뜨리면 "Understood, thank you" 같은 메시지에 다시 "Cannot answer"
# 3줄이 붙는다. 어휘집 json 은 이모지의 뜻이 적힌 정본이라 같이 실어야 한다 —
# 없으면 모듈이 ✅ 하나짜리 폴백으로 내려앉아 🫡·👌·🙇 의 뜻이 통째로 사라진다.
cp "Sources/Plugins/Slack/Daemon/emoji-layer.mjs" "$APP/Contents/Resources/emoji-layer.mjs"
cp "Sources/Plugins/Slack/Daemon/slack-emoji-layer.json" "$APP/Contents/Resources/slack-emoji-layer.json"
# send-layer.mjs 와 novelty-gate.mjs 는 alignment-engine.mjs 가 **정적으로** import 한다.
# 위의 동적 import 동반 모듈과 달리 빠지면 폴백으로 내려앉는 것이 아니라 데몬이 아예
# 뜨지 않는다 (ERR_MODULE_NOT_FOUND). ack-note.mjs 도 데몬이 정적으로 import 한다.
cp "Sources/Plugins/Slack/Daemon/send-layer.mjs" "$APP/Contents/Resources/send-layer.mjs"
cp "Sources/Plugins/Slack/Daemon/novelty-gate.mjs" "$APP/Contents/Resources/novelty-gate.mjs"
cp "Sources/Plugins/Slack/Daemon/ack-note.mjs" "$APP/Contents/Resources/ack-note.mjs"
# reply-language.mjs — 수신자 언어 판정과 출력 언어 검사. 데몬이 **정적으로** import
# 하므로 빠지면 데몬이 아예 안 뜬다 (위 send-layer 와 같은 부류).
cp "Sources/Plugins/Slack/Daemon/reply-language.mjs" "$APP/Contents/Resources/reply-language.mjs"
# security-gate.mjs — 민감정보 요청 게이트. 이것도 데몬이 정적으로 import 하므로
# 빠지면 데몬이 아예 안 뜬다.
cp "Sources/Plugins/Slack/Daemon/security-gate.mjs" "$APP/Contents/Resources/security-gate.mjs"
cp "Sources/Plugins/Slack/Daemon/slack-sensitive-policy.json" "$APP/Contents/Resources/slack-sensitive-policy.json"
# slack-outbound-gate.json — 대외 발신 게이트의 채널→폴더 대응표와 조직 약어 목록.
# alignment-engine.mjs 가 자기 옆에서 이 파일을 읽는다. 빠지면 데몬은 뜨지만 모든
# 채널이 "이름은 있으나 폴더를 모름" 으로 떨어져 확신이 0.9 배로 깎이고, 접두 규칙과
# 약어 검사가 통째로 사라진다 — 코드가 아니라 배치 때문에 게이트가 헐거워지는 자리다.
cp "Sources/Plugins/Slack/Daemon/slack-outbound-gate.json" "$APP/Contents/Resources/slack-outbound-gate.json"
# problem-frame.mjs 는 축 2(문제 정의)의 동적 import 동반 모듈이다. 빠지면 축 2 없이
# 예전대로 돌지만, 그러면 gsk 근거를 실은 F3 지적이 통째로 사라진다. 두 정책 json 은
# 두 에이전트의 페르소나와 등급표의 정본이라 같이 실어야 한다 — 없으면 모듈 안의
# 폴백 문구로 내려앉아 등급표와 금지 목록이 사라진다.
cp "Sources/Plugins/Slack/Daemon/problem-frame.mjs" "$APP/Contents/Resources/problem-frame.mjs"
cp "Sources/Plugins/Slack/Daemon/slack-ack-cost-policy.json" "$APP/Contents/Resources/slack-ack-cost-policy.json"
cp "Sources/Plugins/Slack/Daemon/slack-problem-framing-policy.json" "$APP/Contents/Resources/slack-problem-framing-policy.json"

cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Stamp the source-tree location into the bundle (before signing — the signature covers
# Info.plist) so the running app can offer in-app updates: the rail 설정 menu shows an
# 업데이트 button when sources are newer than this build (GET /api/update/check), and
# pressing it re-runs this script from CMSourceRoot (POST /api/update/run).
/usr/libexec/PlistBuddy -c "Delete :CMSourceRoot" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CMSourceRoot string $PWD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CMBuildStart" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CMBuildStart string $BUILD_START" "$APP/Contents/Info.plist"

IDENTITY="ConditionMate Dev"
# `-v` 는 빼면 안 된다. 없으면 **못 쓰는** 아이덴티티까지 나열된다.
#
# 2026-09-06 에 실제로 그것 때문에 빌드가 통째로 죽었다. 그날 이 맥의 상태가
# `security find-identity -p codesigning` 에서는
#   2) 6643845F… "ConditionMate Dev" (CSSMERR_TP_NOT_TRUSTED)
# 로 나오는데 `-v` 를 붙이면 `0 valid identities found` 였다. 그래서 `grep` 이 걸려 이름 갈래로
# 들어갔고, `codesign` 이 `errSecInternalComponent` 로 실패했고, `set -e` 라 그 자리에서 스크립트가
# 끝났다. 바로 아래 있는 ad-hoc 폴백은 한 번도 안 돌았다 — 곱게 내려가라고 써 둔 갈래가
# 정작 내려가야 할 때 안 돈 것이다.
#
# 아이덴티티가 왜 못 쓰게 됐는지는 이 스크립트가 고칠 일이 아니다. 큐 카드
# `2026-09-05-2346-condition-mate-signing-accessibility-loss` 가 그 건이고 `Scripts/setup-signing.sh`
# 가 그 처방이다. 여기서 하는 일은 "못 쓰면 못 쓴다고 보고 폴백으로 간다" 하나뿐이다.
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
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
BUNDLE_ID="com.lioncho.conditionmate"
INSTALLED="/Applications/$APP"
if [ -d "$INSTALLED" ] || [ "${1:-}" = "--install" ]; then
    echo "==> Updating $INSTALLED"
    # Quit via the normal shutdown path (applicationShouldTerminate), not SIGKILL,
    # so stores flush. Targets prod only — the dev app has the .dev bundle id.
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        # Prod paths only — the dev app (.dev/ConditionMate.app) must not hold the wait.
        pgrep -fq "(/Applications|$PWD)/ConditionMate.app/Contents/MacOS/ConditionMate" || break
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
