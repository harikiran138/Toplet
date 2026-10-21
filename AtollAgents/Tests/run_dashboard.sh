#!/bin/bash
# Focused accounting/game/timer regressions, with no real config files or services.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/atoll-dashboard.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export AA_TMP="$WORK"
cat > "$WORK/Runner.swift" <<'SWIFT'
import Foundation
@main struct DashboardTests {
    static func main() async {
        await runDashboardTests()
        print("Summary: \(TestStats.passed) passed, \(TestStats.failed) failed")
        exit(TestStats.failed == 0 ? 0 : 1)
    }
}
SWIFT
xcrun swiftc -swift-version 5 -parse-as-library -Onone "$HERE"/../Core/*.swift "$HERE/CoreTestSupport.swift" "$HERE/CoreTestsDashboard.swift" "$WORK/Runner.swift" -o "$WORK/tests"
"$WORK/tests"
