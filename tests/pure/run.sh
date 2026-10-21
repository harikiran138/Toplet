#!/bin/bash
# Fast, UI-free tests for Toplet's pure rule files. Command Line Tools only; no Xcode, no app build.
#   tests/pure/run.sh
# Each suite compiles one production file with its test main into a temporary binary and runs it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../../Toplet"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
status=0

run() {  # name, test file, production files…
  local name="$1" test="$2"; shift 2
  local dir="$WORK/$name"; mkdir -p "$dir"
  cp "$test" "$dir/main.swift"
  for f in "$@"; do cp "$f" "$dir/"; done
  # Production files import Defaults; the stub stands in for it so the rules compile alone.
  sed -i '' 's/^import Defaults$//' "$dir"/*.swift
  if xcrun swiftc -O "$dir"/*.swift -o "$dir/t" 2>"$dir/build.log"; then
    if out="$("$dir/t")"; then echo "PASS $name — $out"; else echo "FAIL $name"; echo "$out"; status=1; fi
  else
    echo "BUILD FAIL $name"; cat "$dir/build.log"; status=1
  fi
}

run usage-wording  "$HERE/UsageWordingTests.swift" "$HERE/DefaultsStub.swift" \
    "$APP/managers/LLMUsage/UsageProvider.swift" "$APP/managers/LLMUsage/UsageLimitWording.swift"
run game-boards    "$HERE/GameBoardsTests.swift"   "$APP/managers/Games/NotchGameBoards.swift"
run clock-rules    "$HERE/ClockRulesTests.swift"   "$APP/managers/Clock/ClockRules.swift"
run ship-mood      "$HERE/ShipMoodTests.swift"     "$APP/managers/Ship/ShipMood.swift"
exit $status
