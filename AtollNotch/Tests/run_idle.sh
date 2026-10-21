#!/bin/bash
# Idle animation engine tests. No Xcode, no XCTest: Command Line Tools + swiftc only.
#
#   AtollNotch/Tests/run_idle.sh [output-dir]       (default output: /tmp/atoll-idle-ui)
#
# Part 1 (pure):     AtollNotch/Core/IdleAnimation*.swift + Tests/IdleTests*.swift  -> T4 validators, T5 planner,
#                    T6 migration, preset motion math.
# Part 2 (snapshot): + AtollNotch/UI/Idle*.swift + Tests/Snapshot/*.swift          -> T7 idle film strips rendered
#                    offscreen (NSHostingView / ImageRenderer, no screen-capture permission) with assertions.
#
# Sources are compiled from a private copy (other agents edit AtollNotch/ concurrently). Never touches the user's
# Defaults, ~/Library/Application Support or the running Atoll: all file work happens under a temp dir.
# Exit status is non-zero when any check fails or a build fails.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # AtollNotch
REPO="$(cd "$ROOT/.." && pwd)"
OUT="${1:-/tmp/atoll-idle-ui}"
WORK="$(mktemp -d /tmp/idle-XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$OUT" "$WORK/src/Core" "$WORK/src/UI" "$WORK/src/Tests" "$WORK/tmp"

cp "$ROOT"/Core/IdleAnimation*.swift "$WORK/src/Core/"
cp "$ROOT"/UI/Idle*.swift "$WORK/src/UI/" 2>/dev/null
cp "$HERE"/IdleTest*.swift "$WORK/src/Tests/"
mkdir -p "$WORK/src/Snapshot" && cp "$HERE"/Snapshot/*.swift "$WORK/src/Snapshot/" 2>/dev/null

ARCH="$(uname -m)"
# macOS 14.6 is Atoll's deployment target: building against it makes the compiler reject newer-only SwiftUI API.
TARGET="${ARCH}-apple-macos14.6"
export IDLE_REPO_ROOT="$REPO" IDLE_TMP="$WORK/tmp"
status=0

echo "== lint: no print( / NSLog in the idle engine and its four app files (privacy, CPU in view bodies) =="
LINT_FILES=("$ROOT"/Core/IdleAnimation*.swift "$ROOT"/UI/Idle*.swift \
  "$REPO/Toplet/managers/IdleAnimationManager.swift" "$REPO/Toplet/components/IdleAnimationView.swift" \
  "$REPO/Toplet/components/Settings/IdleAnimationsSettingsSection.swift" "$REPO/Toplet/components/Settings/AnimationEditorView.swift")
if grep -nE '(^|[^A-Za-z_.])(print|NSLog|debugPrint)\(' "${LINT_FILES[@]}"; then echo "FAIL  lint: print/NSLog found"; status=1; else echo "PASS  lint: no print/NSLog in ${#LINT_FILES[@]} files"; fi
if grep -nE 'Timer\.(scheduledTimer|publish)|DispatchSource\.makeTimerSource|CADisplayLink' "$ROOT"/Core/IdleAnimation*.swift "$ROOT"/UI/Idle*.swift; then echo "FAIL  lint: a timer exists in the idle engine (one clock only)"; status=1; else echo "PASS  lint: no Timer / timer source / display link in the idle engine"; fi

echo "== part 1: compiling pure core + tests =="
xcrun swiftc -swift-version 5 -parse-as-library -Onone -target "$TARGET" \
  "$WORK"/src/Core/*.swift "$WORK"/src/Tests/*.swift -o "$WORK/idle-core-tests" 2>"$WORK/build1.log"
if [ $? -ne 0 ]; then cat "$WORK/build1.log"; echo "BUILD FAILED (part 1)"; exit 2; fi
grep -E "warning:" "$WORK/build1.log" | sort -u | head -20
echo "== part 1: running =="
"$WORK/idle-core-tests" || status=1

if ls "$WORK"/src/Snapshot/*.swift >/dev/null 2>&1 && ls "$WORK"/src/UI/Idle*.swift >/dev/null 2>&1; then
  echo "== part 2: compiling UI + snapshot harness =="
  xcrun swiftc -swift-version 5 -parse-as-library -Onone -target "$TARGET" \
    "$WORK"/src/Core/*.swift "$WORK"/src/UI/*.swift "$WORK"/src/Snapshot/*.swift \
    "$WORK"/src/Tests/IdleTestSupport.swift -o "$WORK/idle-snapshot" 2>"$WORK/build2.log"
  if [ $? -ne 0 ]; then cat "$WORK/build2.log"; echo "BUILD FAILED (part 2)"; exit 2; fi
  grep -E "warning:" "$WORK/build2.log" | sort -u | head -20
  echo "== part 2: running (output: $OUT) =="
  "$WORK/idle-snapshot" "$OUT" || status=1
fi
exit $status
