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
struct QueueTestRunner {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
        installCrashHandler()
        print("AtollNotch queue / ingress / facade tests")
        runQueueTests()
        runSanitiserTests()
        await runSocketTests()
        await runScriptTests()
        await runCenterTests()
        await runAdapterTests()
        await runSourceLintTests()
        print("")
        print("== \(TestStats.passed) passed, \(TestStats.failed) failed ==")
        for f in TestStats.failures { print("FAILED: \(f)") }
        exit(TestStats.failed == 0 ? 0 : 1)
    }
}
