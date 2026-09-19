#!/bin/bash
# Run the SwiftPM unit tests (swift-testing).
#
# This repo builds against the Command Line Tools toolchain (no full Xcode), which ships the
# swift-testing frameworks but does NOT put them on the default runtime search path. We therefore
# pass the framework search path at compile time and bake two rpaths into the test bundle so the
# swiftpm-testing-helper can dlopen Testing.framework + lib_TestingInterop.dylib. With full Xcode
# selected these flags are harmless.
#
# 2026-09-07: 시험은 **격리된 데이터 폴더**에서 돈다. `Settings` 는 UserDefaults 가 아니라
# `<CM_DATA_DIR|~/.condition-mate>/settings.json` 에 **진짜로 쓴다.** 도는 앱과 시험 프로세스가
# 같은 파일에 붙으면 두 프로세스가 각자 통째로 덮어써서 상대의 키가 사라진다. 실제로 이날
# `cm.queueFolder` 가 한 번 날아갔고, 앱의 `/api/settings/queue-folder` 로 되돌려 놓았다.
# `AppPaths` 가 이 목적으로 이미 `CM_DATA_DIR` 를 열어 두고 있다("Overridable via CM_DATA_DIR
# so tests never touch the user's real ~/.condition-mate data") — 안 쓰고 있었을 뿐이다.
# 밖에서 `CM_DATA_DIR` 를 이미 정해 놨으면 그것을 존중한다.
set -euo pipefail
cd "$(dirname "$0")/.."

FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
INTEROP="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

# 밖에서 온 `CM_DATA_DIR` 를 그냥 존중하면 안 된다. `.claude/settings.local.json` 이
# `CM_DATA_DIR=/Users/lioncho/.condition-mate` 를 넣어 두므로 "설정돼 있다" 는 것이 곧
# "격리돼 있다" 가 아니다 — 그 값은 실제 store 를 가리킨다. `AppPaths.isCustom` 과 같은 규칙으로
# **경로를 비교해서** 판정한다. 실제 store 를 가리키면 임시 폴더로 갈아탄다.
CM_HOME_STORE="$HOME/.condition-mate"
if [ -z "${CM_DATA_DIR:-}" ] || [ "$(cd "${CM_DATA_DIR}" 2>/dev/null && pwd -P)" = "$(cd "$CM_HOME_STORE" 2>/dev/null && pwd -P)" ]; then
  CM_DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cm-unit-tests-XXXXXX")"
  export CM_DATA_DIR
  trap 'rm -rf "$CM_DATA_DIR"' EXIT
  echo "unit tests: CM_DATA_DIR=$CM_DATA_DIR (격리된 임시 store — 실제 설정을 안 건드린다)"
else
  echo "unit tests: CM_DATA_DIR=$CM_DATA_DIR (밖에서 준 격리 store 를 그대로 쓴다)"
fi

swift test "$@" \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$INTEROP"
