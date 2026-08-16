#!/bin/bash
# Set the QA agent's scan period (minutes). Writes <data_dir>/qa-interval-sec, which
# qa-scan.sh reads on its next base tick — no launchctl reload needed. The dashboard
# "주기" column picks up the new value the next time the app launches.
#
# Usage:  Scripts/qa-set-interval.sh <minutes>     e.g. 10 (default), 30, 60
#         Scripts/qa-set-interval.sh               prints the current period
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -n "${CM_DATA_DIR:-}" ]; then
  data_dir="$CM_DATA_DIR"
else
  data_dir="$HOME/.condition-mate"
fi
mkdir -p "$data_dir"
interval_file="$data_dir/qa-interval-sec"

if [ "$#" -eq 0 ]; then
  cur=600
  [ -f "$interval_file" ] && cur="$(tr -dc '0-9' < "$interval_file")"
  [ -z "$cur" ] && cur=600
  printf '현재 QA 점검 주기: %s초 (%s분)\n' "$cur" "$(( cur / 60 ))"
  exit 0
fi

mins="$1"
case "$mins" in
  ''|*[!0-9]*) echo "오류: 분 단위 정수를 입력하세요 (예: 10)"; exit 1;;
esac
if [ "$mins" -lt 1 ]; then echo "오류: 최소 1분"; exit 1; fi

secs=$(( mins * 60 ))
printf '%s' "$secs" > "$interval_file"
printf 'QA 점검 주기를 %s분(%s초)로 설정했습니다 → %s\n' "$mins" "$secs" "$interval_file"
printf '다음 base tick(최대 60초 내)부터 적용됩니다. 대시보드 "주기" 표시는 앱 재시작 후 갱신됩니다.\n'
