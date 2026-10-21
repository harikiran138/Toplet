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

// Standalone check harness (no XCTest). Every check prints PASS/FAIL; the runner exits non-zero on any FAIL.

enum TestStats {
    static var passed = 0
    static var failed = 0
    static var failures: [String] = []
    static var section = ""
}

func section(_ name: String) {
    TestStats.section = name
    print("-- \(name)")
}

func check(_ ok: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    let base = (("\(file)") as NSString).lastPathComponent
    if ok {
        TestStats.passed += 1
        print("PASS \(name)")
    } else {
        TestStats.failed += 1
        TestStats.failures.append("[\(TestStats.section)] \(name) (\(base):\(line))")
        print("FAIL \(name)  (\(base):\(line))")
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

// MARK: Temp dirs (short: sockets must stay under 104 bytes). Nothing here ever touches ~/.atoll or real preferences.

let testRoot: String = {
    let r = ProcessInfo.processInfo.environment["AN_TMP"] ?? "/tmp/an-\(getpid())"
    mkdir(r, 0o700)
    return r
}()

private var tmpCounter = 0

func makeTmp(_ hint: String = "t") -> String {
    tmpCounter += 1
    let p = "\(testRoot)/\(hint)\(tmpCounter)"
    try? FileManager.default.removeItem(atPath: p)
    mkdir(p, 0o700)
    return p
}

func write(_ path: String, _ text: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
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

/// Runs an executable with arguments (no shell involved) and returns when it exits. Handler driven: it never blocks a
/// cooperative or GCD pool thread, so many of these can run at once.
func runProcess(_ exe: String, _ args: [String], stdin: Data = Data(), env: [String: String] = [:], timeout: TimeInterval = 15) async -> ShellResult {
    await withCheckedContinuation { cont in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
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
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { finish() }
            maybeFinish()
        }
        do { try p.run() } catch { cont.resume(returning: ShellResult(stdout: "", stderr: "launch: \(error)", status: -99)); return }
        let writer = Thread {
            try? inP.fileHandleForWriting.write(contentsOf: stdin)
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

func jsonObject(_ s: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
}

func jsonObject(_ d: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

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

final class Atomic<T> {
    private var v: T
    private let l = NSLock()
    init(_ v: T) { self.v = v }
    func get() -> T { l.withLock { v } }
    func set(_ x: T) { l.withLock { v = x } }
    func mutate(_ f: (inout T) -> Void) { l.withLock { f(&v) } }
}

/// Open unix-domain-socket descriptors of this process.
func socketFDCount() -> Int {
    var n = 0
    for fd in 0..<1024 {
        var st = stat()
        if fstat(Int32(fd), &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK { n += 1 }
    }
    return n
}

// MARK: Fake clock

final class FakeClock {
    var now: Date
    init(_ t: Date = Date(timeIntervalSince1970: 1_000_000)) { now = t }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
    func read() -> Date { now }
}

// MARK: Notification builders

func note(_ title: String = "Title", body: String? = nil, subtitle: String? = nil, app: String = "TestApp", source: NotificationSource = .cli,
          priority: NotificationPriority = .normal, ttl: TimeInterval? = nil, key: String? = nil, thread: String? = nil,
          action: NotificationAction = .none, sensitive: Bool = false, symbol: String? = nil, bundle: String? = nil) -> NotchNotification {
    NotchNotification(source: source, appName: app, bundleID: bundle, iconSymbol: symbol, title: title, subtitle: subtitle, body: body,
                      priority: priority, ttl: ttl, dedupeKey: key, threadID: thread, action: action, isSensitive: sensitive)
}

func enabledSettings(_ f: (inout NotificationSettings) -> Void = { _ in }) -> NotificationSettings {
    var s = NotificationSettings()
    s.enabled = true
    s.rateLimitPerMinute = 100_000
    s.enabledSources = Set(NotificationSource.allCases)
    f(&s)
    return s
}

// MARK: Raw unix-socket client

final class RawClient {
    let fd: Int32
    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, let (addr0, len) = NotificationIngressServer.makeAddress(path) else { return nil }
        var addr = addr0
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
        if rc != 0 { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    func send(_ d: Data) {
        d.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n <= 0 { break }
                off += n
            }
        }
    }
    func send(_ s: String) { send(Data(s.utf8)) }
    func shutdownWrite() { shutdown(fd, SHUT_WR) }
    /// Reads until EOF or `timeout`. Returns (data, sawEOF).
    func readAll(timeout: TimeInterval) -> (Data, Bool) {
        var out = Data()
        let end = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < end {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 50)
            if r > 0 {
                let n = read(fd, &buf, buf.count)
                if n == 0 { return (out, true) }
                if n < 0 { return (out, true) }
                out.append(contentsOf: buf[0..<n])
            }
        }
        return (out, false)
    }
    func closeNow() { close(fd) }

    /// One whole request: send, half-close, read the reply line.
    static func request(path: String, _ payload: String, timeout: TimeInterval = 4) -> (reply: [String: Any]?, raw: String, eof: Bool) {
        guard let c = RawClient(path: path) else { return (nil, "", false) }
        c.send(payload)
        c.shutdownWrite()
        let (d, eof) = c.readAll(timeout: timeout)
        c.closeNow()
        let s = String(decoding: d, as: UTF8.self)
        return (jsonObject(s.trimmingCharacters(in: .whitespacesAndNewlines)), s, eof)
    }
}

// MARK: Fake server for the script tests (records raw payloads; replies with whatever the test says)

final class FakeSocketServer {
    let path: String
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var _payloads: [Data] = []
    private var running = true
    var reply: Data = Data("{\"ok\":true,\"id\":\"00000000-0000-0000-0000-000000000000\"}\n".utf8)
    var replyDelay: TimeInterval = 0
    var payloads: [Data] { lock.lock(); defer { lock.unlock() }; return _payloads }

    init?(dir: String) {
        mkdir(dir, 0o700)
        path = dir + "/f.sock"
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, let (a0, len) = NotificationIngressServer.makeAddress(path) else { return nil }
        var a = a0
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard rc == 0, listen(fd, 16) == 0 else { return nil }
        let t = Thread { [unowned self] in self.loop() }
        t.stackSize = 1 << 20
        t.start()
    }

    private func loop() {
        while true {
            lock.lock(); let go = running; lock.unlock()
            if !go { return }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 100) <= 0 { continue }
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            lock.lock(); _payloads.append(data); let r = reply; let d = replyDelay; lock.unlock()
            if d > 0 { Thread.sleep(forTimeInterval: d) }
            _ = r.withUnsafeBytes { send(c, $0.baseAddress, $0.count, 0) }
            close(c)
        }
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        Thread.sleep(forTimeInterval: 0.25)
        close(fd)
        unlink(path)
    }
}
