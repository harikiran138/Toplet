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

// Private AF_UNIX stream server for `atoll-notify`. Hardening is adapted from AtollAgents/Core/AgentSocketServer.swift
// (security-reviewed): 0700 directory, umask 0177 before bind (socket is 0600 from its first instant), LOCAL_PEERCRED
// uid check, 1 MiB cap, read deadline, connection cap, sun_path 104-byte limit, stale-socket probing, never unlinks a
// file it did not create. No TCP port, no WebSocket, never auto-authorises anybody: any process of the SAME user can
// post (that is the documented trust model), everything else is refused at accept().
//
// Unlike the agent hook socket this one replies (one JSON line), because `atoll-notify` is a user-facing command that
// should tell scripts when a notification was rejected. Nothing is held open waiting for a person: replies are bounded.

enum NotificationIngressError: Error, LocalizedError, Equatable {
    case pathTooLong(Int)
    case insecureDirectory(String)
    case pathOccupied(String)
    case alreadyRunning
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let n): return "Socket path is too long (\(n) bytes, the limit is \(NotificationIngressServer.maxPathBytes))."
        case .insecureDirectory(let m): return m
        case .pathOccupied(let p): return "\(p) exists and is not a socket owned by you; refusing to replace it."
        case .alreadyRunning: return "Another Toplet instance is already listening on the notification socket."
        case .posix(let what, let e): return "\(what) failed: \(String(cString: strerror(e)))."
        }
    }
}

struct IngressPeer: Equatable {
    var uid: uid_t
    var pid: pid_t
}

final class NotificationIngressServer {
    struct Limits: Equatable {
        var maxBytes = 1 << 20                      // 1 MiB per connection
        var readDeadline: TimeInterval = 2          // time to receive a complete request
        var replyDeadline: TimeInterval = 2         // time the handler has to answer
        var maxConnections = 64
        var perPeerPerMinute = 60                   // per peer pid (weak against a shell loop: every `nc` is a new pid)
        var globalPerMinute = 240                   // all peers together
        init() {}
    }

    struct Stats: Equatable {
        var accepted = 0, rejectedPeer = 0, rejectedCap = 0, malformed = 0, tooLarge = 0, timedOut = 0, rateLimited = 0, delivered = 0, replyTimeouts = 0
    }

    /// Handler contract: called on `queue`; must call `reply` exactly once (extra calls are ignored), from any thread.
    typealias Handler = (_ notification: NotchNotification, _ peer: IngressPeer, _ reply: @escaping (IngressReply) -> Void) -> Void

    static let maxPathBytes = 103
    private static let solLocal: Int32 = 0
    private static let localPeerCred: Int32 = 1
    private static let localPeerPid: Int32 = 2

    let socketPath: String
    let limits: Limits
    let expectedUID: uid_t
    let allowedPeerUID: uid_t
    let queue: DispatchQueue
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var onNotification: Handler?

    private let specificKey = DispatchSpecificKey<UInt8>()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var socketIno: ino_t = 0
    private var socketDev: dev_t = 0
    private(set) var isRunning = false
    private var conns: [ObjectIdentifier: Conn] = [:]
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var stats = Stats()
    private var peerStamps: [pid_t: [Date]] = [:]
    private var globalStamps: [Date] = []
    private let clock: () -> Date

    init(socketPath: String? = nil, limits: Limits = Limits(), expectedUID: uid_t = geteuid(), allowedPeerUID: uid_t? = nil,
         queue: DispatchQueue? = nil, clock: @escaping () -> Date = Date.init) {
        self.socketPath = socketPath ?? NotificationIngressServer.defaultSocketPath()
        self.limits = limits
        self.expectedUID = expectedUID
        self.allowedPeerUID = allowedPeerUID ?? expectedUID
        self.queue = queue ?? DispatchQueue(label: "atoll.notify.socket", qos: .userInitiated)
        self.clock = clock
        self.queue.setSpecific(key: specificKey, value: 1)
    }

    deinit { if isRunning { stopLocked() } }

    static func defaultSocketPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".atoll/run/notify.sock")
    }

    /// Same-uid only. This does not authenticate the process (any process of this user may post).
    static func isAllowedPeer(uid peer: uid_t, expected: uid_t) -> Bool { peer == expected }

    /// Pure check for the run and parent directories. Returns a refusal message or nil.
    static func directoryProblem(path: String, isDirectory: Bool, isSymlink: Bool, mode: mode_t, uid: uid_t, expectedUID: uid_t) -> String? {
        if isSymlink { return "\(path) is a symbolic link; refusing to use it for the notification socket." }
        if !isDirectory { return "\(path) is not a directory." }
        if uid != expectedUID { return "\(path) is not owned by you; refusing to put the notification socket there." }
        if mode & 0o077 != 0 { return "\(path) must be mode 0700 (it is \(String(mode & 0o777, radix: 8))); refusing to put the notification socket there." }
        return nil
    }

    // MARK: Start / stop

    func start() throws { try runOnQueueSync { try startLocked() } }

    func stop() {
        if DispatchQueue.getSpecific(key: specificKey) != nil { stopLocked(); return }
        queue.sync { stopLocked() }
        queue.sync {}                               // cancel handlers (which close the fds) were enqueued above: wait for them
    }

    private func runOnQueueSync<T>(_ f: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: specificKey) != nil { return try f() }
        return try queue.sync(execute: f)
    }

    var connectionCount: Int { runOnQueueSync { conns.count } }
    var currentStats: Stats { runOnQueueSync { stats } }

    private func startLocked() throws {
        guard !isRunning else { return }
        let pathBytes = socketPath.utf8.count
        guard pathBytes <= NotificationIngressServer.maxPathBytes, pathBytes > 0 else { throw NotificationIngressError.pathTooLong(pathBytes) }

        try prepareDirectories()
        try clearStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NotificationIngressError.posix("socket", errno) }
        NotificationIngressServer.configure(fd)

        guard let made = NotificationIngressServer.makeAddress(socketPath) else { close(fd); throw NotificationIngressError.pathTooLong(pathBytes) }
        var addr = made.0
        let len = made.1
        let oldMask = umask(0o177)                  // 0600 from the first instant
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        let bindErr = errno
        umask(oldMask)
        guard rc == 0 else { close(fd); throw NotificationIngressError.posix("bind", bindErr) }

        var st = stat()
        guard lstat(socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == expectedUID else {
            close(fd); unlink(socketPath)
            throw NotificationIngressError.pathOccupied(socketPath)
        }
        if st.st_mode & 0o777 != 0o600 {
            chmod(socketPath, 0o600)
            var st2 = stat()
            guard lstat(socketPath, &st2) == 0, st2.st_mode & 0o777 == 0o600 else {
                close(fd); unlink(socketPath)
                throw NotificationIngressError.insecureDirectory("Could not restrict \(socketPath) to mode 0600.")
            }
        }
        socketIno = st.st_ino; socketDev = st.st_dev

        guard listen(fd, 32) == 0 else { let e = errno; close(fd); unlink(socketPath); throw NotificationIngressError.posix("listen", e) }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptReady() }
        src.setCancelHandler { Darwin.close(fd) }
        acceptSource = src
        src.resume()
        isRunning = true
    }

    private func stopLocked() {
        guard isRunning else { return }
        isRunning = false
        for c in Array(conns.values) { requestClose(c) }
        acceptSource?.cancel(); acceptSource = nil
        listenFD = -1
        peerStamps = [:]; globalStamps = []
        var st = stat()
        if lstat(socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_ino == socketIno, st.st_dev == socketDev {
            unlink(socketPath)                      // only the socket we created
        }
    }

    // MARK: Directories / stale socket

    private func prepareDirectories() throws {
        let parent = (socketPath as NSString).deletingLastPathComponent
        let grand = (parent as NSString).deletingLastPathComponent
        var created: Set<String> = []
        var missing: [String] = []
        var cur = parent
        var st = stat()
        while cur != "/" && !cur.isEmpty && lstat(cur, &st) != 0 && errno == ENOENT {
            missing.append(cur)
            cur = (cur as NSString).deletingLastPathComponent
        }
        for dir in missing.reversed() {
            if mkdir(dir, 0o700) != 0 && errno != EEXIST { throw NotificationIngressError.posix("mkdir \(dir)", errno) }
            created.insert(dir)
        }
        var toVerify = [parent]
        if (grand as NSString).lastPathComponent == ".atoll" || created.contains(grand) { toVerify.insert(grand, at: 0) }
        for dir in toVerify {
            var s = stat()
            guard lstat(dir, &s) == 0 else { throw NotificationIngressError.posix("stat \(dir)", errno) }
            let isLink = (s.st_mode & S_IFMT) == S_IFLNK
            let isDir = (s.st_mode & S_IFMT) == S_IFDIR
            if let problem = NotificationIngressServer.directoryProblem(path: dir, isDirectory: isDir, isSymlink: isLink, mode: s.st_mode, uid: s.st_uid, expectedUID: expectedUID) {
                throw NotificationIngressError.insecureDirectory(problem)
            }
        }
    }

    /// Unlinks a leftover socket only when it is a socket owned by us and nobody is listening on it.
    private func clearStaleSocket() throws {
        var st = stat()
        guard lstat(socketPath, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == expectedUID else { throw NotificationIngressError.pathOccupied(socketPath) }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw NotificationIngressError.posix("socket", errno) }
        defer { close(probe) }
        guard let made = NotificationIngressServer.makeAddress(socketPath) else { throw NotificationIngressError.pathTooLong(socketPath.utf8.count) }
        var addr = made.0
        let len = made.1
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, len) } }
        if rc == 0 { throw NotificationIngressError.alreadyRunning }
        let e = errno
        guard e == ECONNREFUSED || e == ENOENT else { throw NotificationIngressError.posix("probe \(socketPath)", e) }
        unlink(socketPath)
    }

    static func makeAddress(_ path: String) -> (sockaddr_un, socklen_t)? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        addr.sun_len = UInt8(len)
        return (addr, len)
    }

    private static func configure(_ fd: Int32) {
        let fl = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func peerUID(_ fd: Int32) -> uid_t? {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, solLocal, localPeerCred, &cred, &len) == 0, cred.cr_version == UInt32(XUCRED_VERSION) else { return nil }
        return cred.cr_uid
    }

    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPid, &pid, &len) == 0 else { return nil }
        return pid
    }

    // MARK: Connections

    private final class Conn {
        enum State { case reading, replying, closed }
        let fd: Int32
        let peer: IngressPeer
        var buffer = Data()
        var state: State = .reading
        var readSource: DispatchSourceRead?
        var timer: DispatchSourceTimer?
        var sourceCancelled = false
        var closeRequested = false
        var fdClosed = false
        init(fd: Int32, peer: IngressPeer) { self.fd = fd; self.peer = peer }
        var id: ObjectIdentifier { ObjectIdentifier(self) }
        func tryClose() {
            if sourceCancelled && closeRequested && !fdClosed { fdClosed = true; Darwin.close(fd) }
        }
    }

    private func acceptReady() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { return }
            handleNew(cfd)
        }
    }

    private func handleNew(_ cfd: Int32) {
        NotificationIngressServer.configure(cfd)
        guard let uid = NotificationIngressServer.peerUID(cfd), NotificationIngressServer.isAllowedPeer(uid: uid, expected: allowedPeerUID) else {
            stats.rejectedPeer += 1; Darwin.close(cfd); return
        }
        guard conns.count < limits.maxConnections else { stats.rejectedCap += 1; Darwin.close(cfd); return }
        stats.accepted += 1
        let pid = NotificationIngressServer.peerPID(cfd) ?? 0
        let c = Conn(fd: cfd, peer: IngressPeer(uid: uid, pid: pid))
        c.buffer.reserveCapacity(4096)
        conns[c.id] = c

        let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: queue)
        src.setEventHandler { [weak self, weak c] in
            guard let self = self, let c = c else { return }
            self.readable(c)
        }
        // Strong capture on purpose: the fd is closed even after the connection left `conns`; released once cancelled.
        src.setCancelHandler {
            c.sourceCancelled = true
            c.tryClose()
        }
        c.readSource = src
        src.resume()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + limits.readDeadline, leeway: .milliseconds(20))
        t.setEventHandler { [weak self, weak c] in
            guard let self = self, let c = c, case .reading = c.state else { return }
            self.stats.timedOut += 1
            // No bytes at all: drop silently. Some bytes but no EOF: process what we have (a complete request still works).
            if c.buffer.isEmpty { self.requestClose(c) } else { self.complete(c) }
        }
        c.timer = t
        t.resume()
    }

    private func readable(_ c: Conn) {
        guard case .reading = c.state else { return }
        var rounds = 0
        while rounds < 64 {
            rounds += 1
            let n = readBuffer.withUnsafeMutableBytes { read(c.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                c.buffer.append(contentsOf: readBuffer[0..<n])
                if c.buffer.count > limits.maxBytes {
                    stats.tooLarge += 1
                    finish(c, .error("payload too large"))
                    return
                }
                continue
            }
            if n == 0 { complete(c); return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            requestClose(c); return
        }
    }

    /// The request is complete (EOF or deadline): stop reading, rate-limit, decode, hand to the handler.
    private func complete(_ c: Conn) {
        guard case .reading = c.state else { return }
        c.state = .replying
        c.timer?.cancel(); c.timer = nil
        c.readSource?.cancel()

        guard admitRate(pid: c.peer.pid) else {
            stats.rateLimited += 1
            finish(c, .error("rate limited"))
            return
        }
        switch NotificationIngressDecoder.decode(c.buffer, now: clock(), fileExists: fileExists) {
        case .failure(let f):
            stats.malformed += 1
            finish(c, .error(f.message))
        case .success(let n):
            c.buffer = Data()
            guard let handler = onNotification else { finish(c, .error("Toplet is not accepting notifications")); return }
            stats.delivered += 1
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + limits.replyDeadline, leeway: .milliseconds(20))
            t.setEventHandler { [weak self, weak c] in
                guard let self = self, let c = c, case .replying = c.state else { return }
                self.stats.replyTimeouts += 1
                self.finish(c, .error("timed out"))
            }
            c.timer = t
            t.resume()
            // The handler may answer from any thread; the answer is marshalled back onto `queue`, exactly once.
            let once = ReplyOnce()
            handler(n, c.peer) { [weak self, weak c] reply in
                guard once.take() else { return }
                self?.queue.async {
                    guard let self = self, let c = c, case .replying = c.state else { return }
                    self.finish(c, reply)
                }
            }
        }
    }

    private final class ReplyOnce {
        private let l = NSLock()
        private var used = false
        func take() -> Bool { l.lock(); defer { l.unlock() }; if used { return false }; used = true; return true }
    }

    private func admitRate(pid: pid_t) -> Bool {
        let now = clock()
        globalStamps = globalStamps.filter { now.timeIntervalSince($0) < 60 }
        if limits.globalPerMinute > 0, globalStamps.count >= limits.globalPerMinute { return false }
        var list = (peerStamps[pid] ?? []).filter { now.timeIntervalSince($0) < 60 }
        if limits.perPeerPerMinute > 0, list.count >= limits.perPeerPerMinute { peerStamps[pid] = list; return false }
        list.append(now)
        peerStamps[pid] = list
        globalStamps.append(now)
        if peerStamps.count > 1024 {                // pids come and go: bound the table
            peerStamps = peerStamps.filter { !$0.value.isEmpty && now.timeIntervalSince($0.value.last ?? .distantPast) < 60 }
        }
        return true
    }

    /// Writes the single reply line (best effort) and closes.
    private func finish(_ c: Conn, _ reply: IngressReply) {
        guard c.state != .closed else { return }
        c.state = .replying
        writeAll(c, reply.line)
        requestClose(c)
    }

    private func requestClose(_ c: Conn) {
        if case .closed = c.state, c.closeRequested { return }
        c.state = .closed
        c.closeRequested = true
        conns.removeValue(forKey: c.id)
        c.timer?.cancel(); c.timer = nil
        if let s = c.readSource, !c.sourceCancelled { s.cancel() } else { c.tryClose() }
    }

    private func writeAll(_ c: Conn, _ data: Data) {
        var offset = 0
        var stalls = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while offset < raw.count, stalls < 20 {
                let n = send(c.fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if n > 0 { offset += n; continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    stalls += 1
                    var p = pollfd(fd: c.fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 100)
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                return
            }
        }
    }
}
