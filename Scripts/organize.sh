#!/bin/bash
# Ingest audio from an inbox folder into the organized BGM library:
#   - estimate BPM
#   - embed/refresh ID3 TBPM tag (lossless -c copy)
#   - rename to "[BPM] Title.ext" (BPM zero-padded => sorts by tempo)
#   - move into the library folder
# Idempotent: an existing "[NNN] " prefix is stripped before re-tagging, so
# re-running never double-prefixes.
#
# Usage: organize.sh [inbox] [library]
#   defaults: inbox = ../temp, library = ../bgm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/temp}"
DEST="${2:-$ROOT/bgm}"
SCRIPTS="$ROOT/Scripts"

mkdir -p "$DEST"
echo "==> Organize: $SRC  ->  $DEST"

moved=0
find "$SRC" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' \
        -o -iname '*.wav' -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.caf' \) -print0 |
while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    ext="${base##*.}"
    name="${base%.*}"
    # Strip an existing "[NNN] " prefix so re-runs stay idempotent.
    clean="$(printf '%s' "$name" | sed -E 's/^\[[0-9]{2,3}\] //')"

    bpm="$(python3 "$SCRIPTS/analyze-bpm.py" "$f" | cut -f1)"
    if [ "$bpm" = "ERR" ] || [ -z "$bpm" ]; then
        echo "  SKIP (no bpm)  $base"
        continue
    fi
    pad="$(printf '%03d' "$bpm")"
    out="$DEST/[$pad] $clean.$ext"

    # mp3/m4a/aac carry ID3; for those embed the tag while copying to dest.
    case "$(printf '%s' "$ext" | tr 'A-Z' 'a-z')" in
        mp3|m4a|aac)
            if ffmpeg -v error -y -i "$f" -c copy \
                -metadata TBPM="$bpm" -write_id3v2 1 -id3v2_version 3 "$out" 2>/dev/null; then
                rm -f "$f"
            else
                mv -f "$f" "$out"   # tag failed: at least move+rename (filename carries BPM)
            fi
            ;;
        *)
            mv -f "$f" "$out"        # wav/aiff/caf: no ID3, filename carries BPM
            ;;
    esac
    echo "  [$pad] $clean.$ext"
    moved=$((moved + 1))
done

echo "==> Done. Library: $DEST"
