/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 */

import Foundation

@main
struct ArbiterTestRunner {
    static func main() {
        let t0 = arbNowNanos()
        arbRunResolverTests()
        arbRunDifferential()
        arbRunSchedulerScenarios()
        arbRunSchedulerFuzz()
        let secs = Double(arbNowNanos() - t0) / 1e9
        print("")
        print("arbiter tests: \(ArbStats.passed) passed, \(ArbStats.failed) failed (\(String(format: "%.1f", secs)) s)")
        if ArbStats.failed > 0 {
            for f in ArbStats.failures { print("  FAILED \(f)") }
            exit(1)
        }
        print("ALL ARBITER CHECKS PASSED")
    }
}
