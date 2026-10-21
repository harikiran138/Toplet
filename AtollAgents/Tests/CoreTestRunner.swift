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
import Darwin

/// Diagnostics: if the test process itself crashes, print the crashing thread's backtrace (pipe through `swift demangle`).
private func installCrashHandler() {
    let size = 1 << 17
    var ss = stack_t(ss_sp: malloc(size), ss_size: size, ss_flags: 0)
    sigaltstack(&ss, nil)
    for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT] {
        var sa = sigaction()
        sa.sa_flags = SA_ONSTACK
        sa.__sigaction_u.__sa_handler = { s in
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
            let n = backtrace(&frames, 64)
            let msg = "\n*** CRASH (signal \(s)) backtrace:\n"
            _ = msg.withCString { write(2, $0, strlen($0)) }
            backtrace_symbols_fd(&frames, n, 2)
            _exit(128 + s)
        }
        sigaction(sig, &sa, nil)
    }
}

@main
struct CoreTestRunner {
    static func main() async {
        // Helper mode: a copy of this (ad-hoc signed) binary stands in for a long-running `claude` process in the
        // libproc tests. (A copied Apple platform binary such as /bin/sleep can be killed by code-signing checks.)
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--aa-sleep" {
            sleep(UInt32(CommandLine.arguments[2]) ?? 30)
            exit(0)
        }
        // Helper modes for the open-file tests: hold a file open / append-and-close repeatedly (what Claude Code does).
        if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--aa-hold" {
            _ = open(CommandLine.arguments[2], O_RDWR | O_CREAT, 0o600)
            sleep(UInt32(CommandLine.arguments[3]) ?? 20)
            exit(0)
        }
        if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--aa-append" {
            let end = Date().addingTimeInterval(Double(CommandLine.arguments[3]) ?? 20)
            while Date() < end {
                let fd = open(CommandLine.arguments[2], O_WRONLY | O_CREAT | O_APPEND, 0o600)
                _ = write(fd, "x\n", 2); close(fd)
                usleep(30_000)
            }
            exit(0)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
        installCrashHandler()
        print("AtollAgents Core tests (fixtures are doc-derived, not yet recorded from a live session)")
        await runDashboardTests()
        runTextTests()
        runEventTests()
        runReducerTests()
        await runServerTests()
        await runDiscoveryTests()
        await runMiscTests()
        await runEngineTests()
        await runCenterTests()
        await runPassiveTests()
        await runPassiveCenterTests()
        print("")
        print("== \(TestStats.passed) passed, \(TestStats.failed) failed ==")
        for f in TestStats.failures { print("FAILED: \(f)") }
        exit(TestStats.failed == 0 ? 0 : 1)
    }
}
