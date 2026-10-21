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

// Minimal assertion framework for the arbiter tests (no XCTest on Command Line Tools).
// Every check prints a PASS/FAIL line (PASS lines are summarised unless ARBITER_VERBOSE is set for the big sweeps).

enum ArbStats {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed = 0
    nonisolated(unsafe) static var section = ""
    nonisolated(unsafe) static var failures: [String] = []
}

func arbSection(_ name: String) {
    ArbStats.section = name
    print("== \(name) ==")
}

func arbCheck(_ name: String, _ ok: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if ok() {
        ArbStats.passed += 1
        print("PASS  \(name)")
    } else {
        ArbStats.failed += 1
        ArbStats.failures.append("[\(ArbStats.section)] \(name)")
        print("FAIL  [\(ArbStats.section)] \(name)  \(detail())")
    }
}

func arbEqual<T: Equatable>(_ name: String, _ a: T, _ b: T) {
    arbCheck(name, a == b, "got \(a), expected \(b)")
}

/// Deterministic generator (SplitMix64). Every sweep prints its seed.
struct ArbRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func bool(_ p: Double = 0.5) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

func arbNowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
