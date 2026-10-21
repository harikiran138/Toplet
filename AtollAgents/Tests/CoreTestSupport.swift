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

// Tiny standalone check harness (no XCTest). Every check prints PASS/FAIL; the runner exits non-zero on any FAIL.

enum TestStats {
    static var passed = 0
    static var failed = 0
    static var failures: [String] = []
    static var section = ""
    static let verbose = ProcessInfo.processInfo.environment["AA_VERBOSE"] != nil
}

func section(_ name: String) {
    TestStats.section = name
    print("-- \(name)")
}

func check(_ ok: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if ok {
        TestStats.passed += 1
        print("PASS \(name)")
    } else {
        TestStats.failed += 1
        TestStats.failures.append("[\(TestStats.section)] \(name) (\((("\(file)") as NSString).lastPathComponent):\(line))")
        print("FAIL \(name)  (\((("\(file)") as NSString).lastPathComponent):\(line))")
    }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if a == b { check(true, name, file: file, line: line) }
    else {
        print("     expected: \(b)")
        print("     actual:   \(a)")
        check(false, name, file: file, line: line)
    }
}

// MARK: Temp dirs (short: sockets must stay under 104 bytes)

let testRoot: String = {
    let r = ProcessInfo.processInfo.environment["AA_TMP"] ?? "/tmp/aa-\(getpid())"
    mkdir(r, 0o700)
    return r
}()

private var tmpCounter = 0

/// A fresh 0700 directory under the test root, e.g. /tmp/aa-123/t4
func makeTmp(_ hint: String = "t") -> String {
    tmpCounter += 1
    let p = "\(testRoot)/\(hint)\(tmpCounter)"
    try? FileManager.default.removeItem(atPath: p)      // never inherit leftovers from an earlier run that used the same root
    mkdir(p, 0o700)
    return p
}

func write(_ path: String, _ text: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
}

func writeData(_ path: String, _ data: Data) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: data)
}

// MARK: Async helpers

func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return cond()
}

func sleepMs(_ ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }

struct ShellResult { var stdout: String; var stderr: String; var status: Int32 }

/// Runs `/bin/sh -c command` with `stdin` and returns when it exits. Never blocks a cooperative or GCD pool thread
/// (64 of these run concurrently in the socket tests): completion is driven by handlers, the stdin writer has its own thread.
func sh(_ command: String, stdin: String = "", timeout: TimeInterval = 10, env: [String: String] = [:]) async -> ShellResult {
    await withCheckedContinuation { cont in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        let inP = Pipe(), outP = Pipe(), errP = Pipe()
        p.standardInput = inP; p.standardOutput = outP; p.standardError = errP

        final class State {
            let lock = NSLock()
            var out = Data(), err = Data()
            var outEOF = false, errEOF = false, exited = false, finished = false
        }
        let st = State()
        func finish() {
            st.lock.lock()
            if st.finished { st.lock.unlock(); return }
            st.finished = true
            let r = ShellResult(stdout: String(decoding: st.out, as: UTF8.self), stderr: String(decoding: st.err, as: UTF8.self), status: p.isRunning ? -15 : p.terminationStatus)
            st.lock.unlock()
            outP.fileHandleForReading.readabilityHandler = nil
            errP.fileHandleForReading.readabilityHandler = nil
            cont.resume(returning: r)
        }
        func maybeFinish() {
            st.lock.lock(); let ready = st.exited && st.outEOF && st.errEOF; st.lock.unlock()
            if ready { finish() }
        }
        outP.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            st.lock.lock(); if d.isEmpty { st.outEOF = true } else { st.out.append(d) }; st.lock.unlock()
            if d.isEmpty { h.readabilityHandler = nil; maybeFinish() }
        }
        errP.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            st.lock.lock(); if d.isEmpty { st.errEOF = true } else { st.err.append(d) }; st.lock.unlock()
            if d.isEmpty { h.readabilityHandler = nil; maybeFinish() }
        }
        p.terminationHandler = { _ in
            st.lock.lock(); st.exited = true; st.lock.unlock()
            // Grandchildren (nc) may keep the pipes open a moment longer; do not wait for them forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { finish() }
            maybeFinish()
        }
        do { try p.run() } catch { cont.resume(returning: ShellResult(stdout: "", stderr: "launch: \(error)", status: -99)); return }
        let data = stdin.data(using: .utf8) ?? Data()
        let writer = Thread {
            try? inP.fileHandleForWriting.write(contentsOf: data)
            try? inP.fileHandleForWriting.close()
        }
        writer.stackSize = 1 << 20
        writer.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { finish() }
        }
    }
}

/// The hook command of research 2.8 (blocking variant for PermissionRequest, `-w 1` variant otherwise), socket path substituted.
func hookCommand(socket: String, agent: String = "claude", blocking: Bool) -> String {
    let nc = blocking ? "/usr/bin/nc -U \"$S\" 2>/dev/null" : "/usr/bin/nc -w 1 -U \"$S\" >/dev/null 2>&1"
    return "S=\"\(socket)\"; [ -S \"$S\" ] || exit 0; { printf '{\"v\":1,\"agent\":\"\(agent)\",\"ppid\":%s}\\n' \"$PPID\"; cat; } | \(nc); exit 0"
}

func jsonString(_ obj: Any) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    return String(decoding: d, as: UTF8.self)
}

func jsonObject(_ s: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
}

/// Deterministic PRNG for the fuzz tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Lock-protected value usable from async tests and background closures.
final class Atomic<T> {
    private var v: T
    private let l = NSLock()
    init(_ v: T) { self.v = v }
    func get() -> T { l.withLock { v } }
    func set(_ x: T) { l.withLock { v = x } }
    func mutate(_ f: (inout T) -> Void) { l.withLock { f(&v) } }
}

/// Open unix-domain-socket descriptors of this process (what the agent server owns). Pipes and files used by the
/// test helpers come and go and would make a total fd count noisy.
func socketFDCount() -> Int {
    var n = 0
    for fd in 0..<1024 {
        var st = stat()
        if fstat(Int32(fd), &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK { n += 1 }
    }
    return n
}

/// Terminates a child and waits for it WITHOUT Process.waitUntilExit (which can hang when called from a cooperative-pool thread).
func reap(_ p: Process) async {
    if p.isRunning { p.terminate() }
    let end = Date().addingTimeInterval(5)
    while p.isRunning && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
}
