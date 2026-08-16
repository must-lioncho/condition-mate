#!/usr/bin/env bash
# Dev launcher. DATA IS SHARED with the installed app: the single ~/.condition-mate
# store (AppPaths.base). The old repo-local .localdata isolation was retired 2026-07-09 —
# two stores made goals/settings diverge and "disappear" when switching dev↔prod. Set
# CM_DATA_DIR explicitly before running for a throwaway/isolated run.
#
# Build → SIGN → run (not `swift run`): signing the binary with a stable identity
# keeps the Accessibility (TCC) grant alive across rebuilds. See Scripts/setup-signing.sh.
set -euo pipefail

# Project root = parent of this Scripts/ dir, regardless of where it's invoked from.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IDENTITY="ConditionMate Dev"
BUNDLE_ID="com.lioncho.conditionmate"
BIN=".build/debug/ConditionMate"

echo "[dev-run] data=${CM_DATA_DIR:-$HOME/.condition-mate (shared with prod)}"
echo "[dev-run] building"
swift build "$@"

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "[dev-run] signing with '$IDENTITY' (stable Accessibility grant)"
    # -i pins the identifier so the designated requirement stays identical across
    # rebuilds: identifier "<BUNDLE_ID>" and certificate leaf = H"<our cert>".
    codesign --force --sign "$IDENTITY" -i "$BUNDLE_ID" "$BIN"
else
    echo "[dev-run] WARNING: signing identity '$IDENTITY' not found." >&2
    echo "[dev-run] Run Scripts/setup-signing.sh once so Accessibility survives rebuilds." >&2
fi

echo "[dev-run] launching"
exec "$BIN"
