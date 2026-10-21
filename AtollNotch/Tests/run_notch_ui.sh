#!/bin/bash
# Renders the notch notification UI (compact wings, expanded card, Notifications and Integrations settings sections) to PNGs
# offscreen and asserts invariants. No Xcode needed: Command Line Tools + swiftc only. No screen-capture permission needed
# (NSHostingView + cacheDisplay, ImageRenderer for Liquid Glass). Runs the harness TWICE, once per surface path:
#   <out>/fallback  material path (ATOLL_NOTCH_UI_SURFACE=fallback)
#   <out>/glass     Liquid Glass path (ATOLL_NOTCH_UI_SURFACE=glass; needs macOS 26+, otherwise it is skipped)
#
#   AtollNotch/Tests/run_notch_ui.sh [output-dir]      (default: /tmp/atoll-notch-ui)
#
# Exit status is non-zero when any PASS/FAIL line fails or the build fails.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${1:-/tmp/atoll-notch-ui}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/atoll_notch_ui_snapshot"
mkdir -p "$OUT"

# Compile from a private copy: other agents edit AtollNotch/ while this runs. Only the shared contract is taken from Core/.
mkdir -p "$WORK/src/Core" "$WORK/src/UI" "$WORK/src/Tests"
cp "$ROOT/Core/NotchNotification.swift" "$WORK/src/Core/"
# Only this feature's files: the idle engine owns other files in UI/ and Core/.
cp "$ROOT"/UI/NotchUI*.swift "$ROOT"/UI/Notification*.swift "$ROOT"/UI/Integrations*.swift "$WORK/src/UI/"
cp "$ROOT"/Tests/UI*.swift "$WORK/src/Tests/"

# macOS 14.6 is Atoll's deployment target: building against it makes the compiler reject newer-only SwiftUI API.
ARCH="$(uname -m)"
xcrun swiftc -swift-version 5 -parse-as-library -Onone \
  -target "${ARCH}-apple-macos14.6" \
  "$WORK"/src/Core/*.swift \
  "$WORK"/src/UI/*.swift \
  "$WORK"/src/Tests/*.swift \
  -o "$BIN"

status=0
for mode in fallback glass; do
  echo "=== surface: $mode ==="
  ATOLL_NOTCH_UI_SURFACE="$mode" "$BIN" "$OUT/$mode" || status=1
done
exit $status
