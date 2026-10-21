#!/bin/bash
# Compiles AtollNotch/Core/NotchEventArbiter*.swift + AtollNotch/Tests/Arbiter*.swift into a standalone test binary and runs it.
# No XCTest, no Xcode: Command Line Tools + swiftc only. Foundation only; touches nothing outside a temp dir.
# -O is used on purpose: the performance check (resolve() < 5 us average) is meaningless at -Onone.
# Usage: AtollNotch/Tests/run_arbiter.sh      exit status != 0 when any check fails (2 = build failure).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d /tmp/arbiter.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "== compiling Core/NotchEventArbiter*.swift + Tests/Arbiter*.swift =="
xcrun swiftc -swift-version 5 -parse-as-library -O -o "$TMP/arbiter-tests" \
  "$ROOT"/Core/NotchEventArbiter*.swift "$HERE"/Arbiter*.swift 2>"$TMP/build.log"
if [ $? -ne 0 ]; then
  cat "$TMP/build.log"
  echo "BUILD FAILED"
  exit 2
fi
grep -E "warning:" "$TMP/build.log" | sort -u | head -20
echo "== running =="
"$TMP/arbiter-tests"
