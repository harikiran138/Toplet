#!/bin/bash
# Copy the AI-agents sources from AtollAgents/ (tested standalone) into an Atoll tree so the overlay build compiles them.
#   local/sync-agents.sh [DEST_REPO_ROOT]     default: this repo
# Core + Hooks  -> Toplet/managers/Agents/      UI (without the snapshot harness) -> Toplet/components/Notch/Agents/
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/AtollAgents"
DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
mkdir -p "$DEST/Toplet/managers/Agents" "$DEST/Toplet/components/Notch/Agents"
rm -f "$DEST"/Toplet/managers/Agents/*.swift "$DEST"/Toplet/components/Notch/Agents/*.swift
cp "$SRC"/Core/*.swift "$SRC"/Hooks/*.swift "$DEST/Toplet/managers/Agents/"
cp "$SRC"/UI/*.swift "$DEST/Toplet/components/Notch/Agents/"
echo "synced: $(ls "$DEST"/Toplet/managers/Agents | wc -l | tr -d ' ') core/hooks files, $(ls "$DEST"/Toplet/components/Notch/Agents | wc -l | tr -d ' ') UI files -> $DEST"
