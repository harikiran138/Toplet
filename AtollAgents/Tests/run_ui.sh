#!/bin/bash
# Renders the Agents UI (notch view, closed indicator, settings section) to PNGs offscreen and asserts invariants.
# No Xcode needed: Command Line Tools + swiftc only. No screen-capture permission needed (NSHostingView + cacheDisplay,
# ImageRenderer for Liquid Glass). Runs the harness TWICE, once per surface path, on any macOS version:
#   <out>/fallback  material path (ATOLL_AGENTS_SURFACE=fallback)
#   <out>/glass     Liquid Glass path (ATOLL_AGENTS_SURFACE=glass; needs macOS 26+, otherwise it is skipped)
#
#   AtollAgents/Tests/run_ui.sh [output-dir]      (default: /tmp/atoll-agents-ui)
#
# Exit status is non-zero when any PASS/FAIL line fails or the build fails.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${1:-/tmp/atoll-agents-ui}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/atoll_agents_ui_snapshot"
mkdir -p "$OUT"

# Compile from a private copy: other agents edit Core/ while this runs.
mkdir -p "$WORK/src"
cp -R "$ROOT/Core" "$ROOT/UI" "$WORK/src/"

# macOS 14.6 is Atoll's deployment target: building against it makes the compiler reject newer-only SwiftUI API.
ARCH="$(uname -m)"
xcrun swiftc -swift-version 5 -parse-as-library -Onone \
  -target "${ARCH}-apple-macos14.6" \
  "$WORK"/src/Core/*.swift \
  "$WORK"/src/UI/*.swift \
  "$WORK"/src/UI/Snapshot/*.swift \
  -o "$BIN"

status=0
for mode in fallback glass; do
  echo "=== surface: $mode ==="
  ATOLL_AGENTS_SURFACE="$mode" "$BIN" "$OUT/$mode" || status=1
done
exit $status
