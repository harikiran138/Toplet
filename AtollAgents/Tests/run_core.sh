#!/bin/bash
# Compiles AtollAgents/Core/*.swift + AtollAgents/Tests/Core*.swift into a standalone test binary and runs it.
# No XCTest, no Xcode: Command Line Tools + swiftc only. Never touches the real ~/.claude, ~/.codex or ~/.atoll
# (every path is injected and lives under a short temp dir, because sun_path is 104 bytes).
# Usage: AtollAgents/Tests/run_core.sh [-v]     exit status != 0 when any check fails.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export AA_TMP="/tmp/aa-$$"
BIN="$AA_TMP/bin"
mkdir -p "$BIN" && chmod 700 "$AA_TMP"
cleanup() { rm -rf "$AA_TMP"; }
trap cleanup EXIT

echo "== compiling Core + Tests/Core* =="
xcrun swiftc -swift-version 5 -parse-as-library -Onone -o "$BIN/core-tests" "$ROOT"/Core/*.swift "$HERE"/Core*.swift 2>"$AA_TMP/build.log"
if [ $? -ne 0 ]; then
  cat "$AA_TMP/build.log"
  echo "BUILD FAILED"
  exit 2
fi
grep -E "warning:" "$AA_TMP/build.log" | sort -u | head -20
echo "== running =="
if [ "${1:-}" = "-v" ]; then export AA_VERBOSE=1; fi
"$BIN/core-tests"
