#!/usr/bin/env bash
# Dev launcher: keep the app's JSON "DB" inside the project folder (gitignored)
# instead of ~/Library/Application Support, so it survives OS re-setup and stays
# next to the code. AppPaths reads CM_DATA_DIR; see Sources/.../Core/AppPaths.swift.
#
# Data lives in .localdata/ : stats.json, review/goals.json, activity/*.jsonl, evidence/...
# NOTE: app Settings (music folder, tracked apps, BPM, volume) still use UserDefaults,
# not this folder — to be unified when we split out a real store later.
#
# Build → SIGN → run (not `swift run`): signing the binary with a stable identity
# keeps the Accessibility (TCC) grant alive across rebuilds. See Scripts/setup-signing.sh.
set -euo pipefail

# Project root = parent of this Scripts/ dir, regardless of where it's invoked from.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Dev runtime store is repo-local and isolated: <root>/.localdata (gitignored). This keeps
# dev runs from ever touching the production home store (~/.condition-manager). Because this
# path is INSIDE the repo, IssuePaths.root resolves goal definitions to <root>/.issue, so dev
# goals stay git-tracked next to the code.
export CM_DATA_DIR="$ROOT/.localdata"
mkdir -p "$CM_DATA_DIR"
cd "$ROOT"

IDENTITY="ConditionManager Dev"
BUNDLE_ID="com.lioncho.conditionmanager"
BIN=".build/debug/ConditionManager"

echo "[dev-run] CM_DATA_DIR=$CM_DATA_DIR"
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
