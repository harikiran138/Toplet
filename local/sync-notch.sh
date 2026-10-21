#!/bin/bash
# Copy the idle-animation engine from AtollNotch/ (tested standalone) into the app tree, so the Xcode
# project (which only compiles Toplet/) and the local overlay build see the same files.
#   local/sync-notch.sh [DEST_REPO_ROOT]     default: this repo
# AtollNotch/Core/IdleAnimation*.swift + AtollNotch/UI/Idle*.swift -> Toplet/AtollNotchIdle/
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/AtollNotch"
DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)}/Toplet/AtollNotchIdle"
mkdir -p "$DEST"
rm -f "$DEST"/*.swift
cp "$SRC"/Core/IdleAnimation*.swift "$SRC"/UI/Idle*.swift "$DEST/"
echo "synced: $(ls "$DEST" | wc -l | tr -d ' ') idle-animation files -> $DEST"
