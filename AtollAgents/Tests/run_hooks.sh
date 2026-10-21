#!/bin/sh
# Builds AtollAgents/Hooks/*.swift (+ the Core files they depend on) with plain swiftc and runs the hook tests.
# No Xcode needed. Prints PASS/FAIL lines; exits non-zero on any failure. All file operations happen in a temp dir.
#
#   AtollAgents/Tests/run_hooks.sh            # build + run
#   AtollAgents/Tests/run_hooks.sh -q         # only FAIL lines and the summary
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
A="$ROOT/AtollAgents"
OUT="${TMPDIR:-/tmp}/atoll-hooks-tests-build.$$"
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

# Hooks needs AgentKind (AgentModels.swift), HooksState (AgentCenter.swift) and the HookInstalling protocol
# (HookInstalling.swift). Try that minimal Core set first; if the core agent's files grew dependencies, fall back to all of Core.
MIN="$A/Core/AgentModels.swift $A/Core/AgentCenter.swift"
[ -f "$A/Core/HookInstalling.swift" ] && MIN="$MIN $A/Core/HookInstalling.swift"
# shellcheck disable=SC2086
if ! swiftc -swift-version 5 -parse-as-library -O -o "$OUT/hooks-tests" "$A"/Hooks/*.swift $MIN "$A/Tests/HooksTests.swift" 2>"$OUT/build.log"; then
    echo "minimal Core set did not build, retrying with all of Core/*.swift" >&2
    swiftc -swift-version 5 -parse-as-library -O -o "$OUT/hooks-tests" "$A"/Hooks/*.swift "$A"/Core/*.swift "$A/Tests/HooksTests.swift"
fi

set +e
"$OUT/hooks-tests" > "$OUT/log" 2>&1
STATUS=$?
set -e
if [ "${1:-}" = "-q" ]; then
    grep -E '^(FAIL|SKIP|[0-9]+ checks|ALL PASS|FAILURES)' "$OUT/log" || true
else
    cat "$OUT/log"
fi
exit $STATUS
