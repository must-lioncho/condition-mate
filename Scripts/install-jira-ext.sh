#!/bin/bash
# 지라 번역 크롬 익스텐션을 이 컴퓨터에 설치(복사)한다.
#
# 왜 복사하는가: 레포의 원본에는 연결 토큰이 없다(깃에 비밀값을 넣지 않는다).
# 이 스크립트가 앱이 만든 토큰을 읽어 설치본의 config.js 에 심는다. 그래서 크롬은
# 레포 폴더가 아니라 설치본 폴더를 "압축해제된 확장 프로그램"으로 불러와야 한다.
#
# 사용법:  Scripts/install-jira-ext.sh
# 소스를 고친 뒤에는 다시 실행하고, 크롬 확장 프로그램 화면에서 새로고침을 누른다.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/Sources/Plugins/Jira/Extension"
DATA_DIR="${CM_DATA_DIR:-$HOME/.condition-mate}"
TOKEN_FILE="$DATA_DIR/jira-bridge/token"
DEST="$DATA_DIR/chrome-jira-translate"

[ -d "$SRC" ] || { echo "익스텐션 소스를 찾을 수 없습니다: $SRC" >&2; exit 1; }

if [ ! -f "$TOKEN_FILE" ]; then
  echo "연결 토큰이 아직 없습니다: $TOKEN_FILE" >&2
  echo "컨디션 매니저 앱을 한 번 실행한 뒤(브리지가 토큰을 만듭니다) 다시 실행하세요." >&2
  exit 1
fi
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
[ -n "$TOKEN" ] || { echo "토큰 파일이 비어 있습니다: $TOKEN_FILE" >&2; exit 1; }

mkdir -p "$DEST"
# 설치본은 통째로 갈아끼운다 — 지운 파일이 남아 있으면 크롬이 옛 코드를 계속 쓴다.
rm -rf "${DEST:?}"/*
cp "$SRC"/manifest.json "$SRC"/background.js "$SRC"/content.js "$SRC"/content.css \
   "$SRC"/options.html "$SRC"/options.js "$DEST/"

cat > "$DEST/config.js" <<EOF
// 이 파일은 Scripts/install-jira-ext.sh 가 만들었다. 직접 고치지 말 것.
globalThis.CMJT_CONFIG = {
  bridge: 'http://127.0.0.1:17321',
  token: '$TOKEN',
  lang: 'ko',
};
EOF
chmod 600 "$DEST/config.js"

echo "설치 완료: $DEST"
echo
echo "크롬에서 한 번만 해 주세요:"
echo "  1. chrome://extensions 를 연다"
echo "  2. 오른쪽 위 '개발자 모드'를 켠다"
echo "  3. '압축해제된 확장 프로그램을 로드합니다' → 위 폴더를 고른다"
echo
echo "이미 로드해 두었다면 그 카드의 새로고침 버튼만 누르면 됩니다."
