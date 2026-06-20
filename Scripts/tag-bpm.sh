#!/bin/bash
# Estimate BPM for each audio file in a folder and embed it into the ID3 TBPM
# tag (lossless, -c copy). Re-runnable: existing TBPM tags are overwritten.
#
# Usage: tag-bpm.sh [folder]   (defaults to ../temp)
set -euo pipefail

DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/temp}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Tagging audio in: $DIR"
count=0
find "$DIR" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' \) -print0 |
while IFS= read -r -d '' f; do
    bpm=$(python3 "$SCRIPT_DIR/analyze-bpm.py" "$f" | cut -f1)
    if [ "$bpm" = "ERR" ] || [ -z "$bpm" ]; then
        echo "  SKIP (no bpm)  $(basename "$f")"
        continue
    fi
    tmp="${f%.*}.__tagged.${f##*.}"
    if ffmpeg -v error -y -i "$f" -c copy \
        -metadata TBPM="$bpm" -write_id3v2 1 -id3v2_version 3 "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f"
        echo "  $bpm BPM       $(basename "$f")"
        count=$((count + 1))
    else
        rm -f "$tmp"
        echo "  FAIL (tag)     $(basename "$f")"
    fi
done

echo "==> Done"
