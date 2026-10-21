#!/bin/bash
# Compiles AtollNotch/Core (contract, queue, ingress, facade, adapters) + AtollNotch/Tests/Queue*.swift into a standalone
# test binary and runs it. No XCTest, no Xcode: Command Line Tools + swiftc only. Never touches ~/.atoll, ~/.claude or any real
# preferences: every path is injected and lives under a short temp dir (sun_path is 104 bytes), and the script under test
# is run with ATOLL_NOTIFY_SOCKET and HOME pointing into that dir.
# Usage: AtollNotch/Tests/run_queue.sh [-v]     exit status != 0 when any check fails (2 = build failed).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
export AN_TMP="/tmp/an-$$"
export AN_NOTIFY_SCRIPT="$REPO/scripts/atoll-notify"
BIN="$AN_TMP/bin"
mkdir -p "$BIN" && chmod 700 "$AN_TMP"
cleanup() { rm -rf "$AN_TMP"; }
trap cleanup EXIT

SOURCES=(
  "$ROOT/Core/NotchNotification.swift"
  "$ROOT/Core/NotificationQueue.swift"
  "$ROOT"/Core/NotificationIngress*.swift
  "$ROOT/Core/NotchNotificationCenter.swift"
  "$ROOT"/Core/NotificationAdapters*.swift
  "$HERE"/Queue*.swift
)

echo "== compiling Core + Tests/Queue* =="
xcrun swiftc -swift-version 5 -parse-as-library -Onone -o "$BIN/queue-tests" "${SOURCES[@]}" 2>"$AN_TMP/build.log"
if [ $? -ne 0 ]; then
  cat "$AN_TMP/build.log"
  echo "BUILD FAILED"
  exit 2
fi
# Only warnings in the product code matter here (the test harness has benign Swift 6 concurrency notes).
grep -E "AtollNotch/Core/.*warning:" "$AN_TMP/build.log" | sort -u | head -20

echo "== script syntax =="
for sh in /bin/sh /bin/dash; do
  [ -x "$sh" ] && { "$sh" -n "$AN_NOTIFY_SCRIPT" && echo "PASS $sh -n scripts/atoll-notify" || { echo "FAIL $sh -n scripts/atoll-notify"; exit 1; }; }
done

echo "== running =="
if [ "${1:-}" = "-v" ]; then export AN_VERBOSE=1; fi
"$BIN/queue-tests"
