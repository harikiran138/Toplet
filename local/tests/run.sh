#!/bin/bash
# Tests that run with Command Line Tools only (no Xcode / XCTest).
#  1. local/tests/state_semantics.swift: proves that the AtollState alias (= real SwiftUI.State) keeps
#     per-view state across body re-evaluations, supports $binding, init(initialValue:) and optionals.
#  2. local/tests/asset_lookup.swift: Image("name")/NSImage(named:) against the converted loose resources
#     (needs `python3 local/prepare.py` to have produced local/.work/resources)
#  3. the repo's own standalone tests: tests/*.py, tests/test_cursor_quota_payload.swift
#     (tests/test_claude_keychain.* touch the Keychain and are NEVER run here).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
echo "== state semantics"
swiftc -swift-version 5 -target arm64-apple-macosx14.6 -o "$T/state" "$HERE/state_semantics.swift"
"$T/state"
echo "== asset lookup (shim + converted resources)"
if [ -d "$HERE/../.work/resources" ]; then
  B="$T/T.app/Contents"; mkdir -p "$B/MacOS" "$B/Resources"
  cp "$HERE"/../.work/resources/{bolt.png,spotlight.svg,desktop.jpeg,logo.png,Github.svg} "$B/Resources/"
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.assettest</string><key>CFBundleExecutable</key><string>T</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>' > "$B/Info.plist"
  mkdir -p "$T/src"; cp "$HERE/../shims/AtollAssets.swift" "$T/src/AtollAssets.swift"; cp "$HERE/asset_lookup.swift" "$T/src/main.swift"
  swiftc -swift-version 5 -target arm64-apple-macosx14.6 -o "$B/MacOS/T" "$T/src/AtollAssets.swift" "$T/src/main.swift"
  "$B/MacOS/T"
else echo "skipped: run local/prepare.py first"; fi
echo "== repo python tests"
python3 "$REPO/tests/test_privacy_configuration.py"
python3 "$REPO/tests/test_timer_lifecycle.py"
echo "== repo standalone swift test (cursor quota payload)"
swiftc -swift-version 5 "$REPO/Toplet/managers/LLMUsage/Quota/CursorQuotaPayload.swift" \
  "$REPO/tests/test_cursor_quota_payload.swift" -o "$T/cursor"
"$T/cursor"
