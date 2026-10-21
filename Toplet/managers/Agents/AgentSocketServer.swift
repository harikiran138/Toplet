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

// POSIX AF_UNIX stream server for the agent hooks (docs/AI-AGENTS-RESEARCH.md 5.2).
// Wire format: first line `{"v":1,"agent":"claude|codex","ppid":N}`, then the hook JSON, EOF-terminated
// (macOS `nc -U` half-closes on stdin EOF). Non-blocking events get NO reply. Only PermissionRequest keeps its
// connection open, and only `ApprovalBroker.decide` can answer it. Anything the server writes is a single JSON
// object built from an enum; stray text on stdout would be injected into Claude's context for some events.

enum AgentServerError: Error, LocalizedError, Equatable {
    case pathTooLong(Int)
    case insecureDirectory(String)
    case pathOccupied(String)
    case alreadyRunning
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let n): return "Socket path is too long (\(n) bytes, the limit is \(AgentSocketServer.maxPathBytes))."
        case .insecureDirectory(let m): return m
        case .pathOccupied(let p): return "\(p) exists and is not a socket owned by you; refusing to replace it."
        case .alreadyRunning: return "Another Toplet instance is already listening on the agent socket."
        case .posix(let what, let e): return "\(what) failed: \(String(cString: strerror(e)))."
        }
    }
}

final class AgentSocketServer {
    struct Limits: Equatable {
        var maxBytes = 1 << 20                  // 1 MiB per connection
        var readDeadline: TimeInterval = 2      // time to receive a complete payload
        var maxConnections = 64
        var maxPending = 16
        var approvalTimeout: TimeInterval = 90  // after this: write nothing, close, the agent asks in its own UI
        init() {}
    }

    struct Stats: Equatable {
        var accepted = 0, rejectedPeer = 0, rejectedCap = 0, malformed = 0, tooLarge = 0, timedOut = 0, events = 0, approvals = 0
    }

    /// macOS sun_path is 104 bytes including the NUL.
    static let maxPathBytes = 103
    private static let solLocal: Int32 = 0
    private static let localPeerCred: Int32 = 1
    private static let localPeerPid: Int32 = 2

    let socketPath: String
    let limits: Limits
    let expectedUID: uid_t
    /// Peers must have this uid (LOCAL_PEERCRED). Defaults to `expectedUID`; separate so tests can simulate a foreign peer.
    let allowedPeerUID: uid_t
    let queue: DispatchQueue
    let broker: ApprovalBroker

    /// Called on `queue` for every decoded event (including the PermissionRequest that creates a pending approval).
    var onEvent: ((AgentEvent) -> Void)?

    private let specificKey = DispatchSpecificKey<UInt8>()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var acceptCancelled = true
    private var socketIno: ino_t = 0
    private var socketDev: dev_t = 0
    private(set) var isRunning = false
    private var conns: [ObjectIdentifier: Conn] = [:]
    private var watchTimer: DispatchSourceTimer?
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    private(set) var stats = Stats()

    // MARK: Init / paths

    init(socketPath: String? = nil, limits: Limits = Limits(), expectedUID: uid_t = geteuid(), allowedPeerUID: uid_t? = nil, queue: DispatchQueue? = nil) {
        self.socketPath = socketPath ?? AgentSocketServer.defaultSocketPath()
        self.limits = limits
        self.expectedUID = expectedUID
        self.allowedPeerUID = allowedPeerUID ?? expectedUID
        self.queue = queue ?? DispatchQueue(label: "atoll.agents.socket", qos: .userInitiated)
        self.queue.setSpecific(key: specificKey, value: 1)
        self.broker = ApprovalBroker(queue: self.queue, maxPending: limits.maxPending, timeout: limits.approvalTimeout)
    }

    deinit { if isRunning { stopLocked() } }

    static func defaultSocketPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".atoll/run/agent.sock")
    }

    /// Whether `peer` may talk to us. Same-uid only (this does not authenticate the process, see research 5.2).
    static func isAllowedPeer(uid peer: uid_t, expected: uid_t) -> Bool { peer == expected }

    /// Pure check used for both the run and parent directories. Returns a refusal message or nil when acceptable.
    static func directoryProblem(path: String, isDirectory: Bool, isSymlink: Bool, mode: mode_t, uid: uid_t, expectedUID: uid_t) -> String? {
        if isSymlink { return "\(path) is a symbolic link; refusing to use it for the agent socket." }
        if !isDirectory { return "\(path) is not a directory." }
        if uid != expectedUID { return "\(path) is not owned by you; refusing to put the agent socket there." }
        if mode & 0o077 != 0 { return "\(path) must be mode 0700 (it is \(String(mode & 0o777, radix: 8))); refusing to put the agent socket there." }
        return nil
    }

    // MARK: Start / stop

    func start() throws {
        try runOnQueueSync { try startLocked() }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: specificKey) != nil { stopLocked(); return }
        queue.sync { stopLocked() }
        // Cancel handlers (which close the fds) were enqueued above: wait for them.
        queue.sync {}
    }

    private func runOnQueueSync<T>(_ f: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: specificKey) != nil { return try f() }
        return try queue.sync(execute: f)
    }

    var connectionCount: Int { runOnQueueSync { conns.count } }
    var pendingCount: Int { broker.count }
    var currentStats: Stats { runOnQueueSync { stats } }

    private func startLocked() throws {
        guard !isRunning else { return }
        let pathBytes = socketPath.utf8.count
        guard pathBytes <= AgentSocketServer.maxPathBytes, pathBytes > 0 else { throw AgentServerError.pathTooLong(pathBytes) }

        try prepareDirectories()
        try clearStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentServerError.posix("socket", errno) }
        AgentSocketServer.configure(fd)

        guard let made = AgentSocketServer.makeAddress(socketPath) else { close(fd); throw AgentServerError.pathTooLong(pathBytes) }
        var addr = made.0
        let len = made.1
        let oldMask = umask(0o177)                     // the socket is created 0600 from the first instant
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        let bindErr = errno
        umask(oldMask)
        guard rc == 0 else { close(fd); throw AgentServerError.posix("bind", bindErr) }

        var st = stat()
        guard lstat(socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == expectedUID else {
            close(fd); unlink(socketPath)
            throw AgentServerError.pathOccupied(socketPath)
        }
        if st.st_mode & 0o777 != 0o600 {
            chmod(socketPath, 0o600)
            var st2 = stat()
            guard lstat(socketPath, &st2) == 0, st2.st_mode & 0o777 == 0o600 else {
                close(fd); unlink(socketPath)
                throw AgentServerError.insecureDirectory("Could not restrict \(socketPath) to mode 0600.")
            }
        }
        socketIno = st.st_ino; socketDev = st.st_dev

        guard listen(fd, 32) == 0 else { let e = errno; close(fd); unlink(socketPath); throw AgentServerError.posix("listen", e) }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        acceptCancelled = false
        src.setEventHandler { [weak self] in self?.acceptReady() }
        src.setCancelHandler { [weak self] in
            self?.acceptCancelled = true
            Darwin.close(fd)
        }
        acceptSource = src
        src.resume()
        isRunning = true
    }

    private func stopLocked() {
        guard isRunning else { return }
        isRunning = false
        // Pending approvals: write nothing, close (the agent shows its own prompt).
        broker.cancelAll(reason: .serverStopped)
        for c in Array(conns.values) { requestClose(c) }
        watchTimer?.cancel(); watchTimer = nil
        acceptSource?.cancel(); acceptSource = nil
        listenFD = -1
        // Remove our socket file, but only if it is still the one we created.
        var st = stat()
        if lstat(socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_ino == socketIno, st.st_dev == socketDev {
            unlink(socketPath)
        }
    }

    // MARK: Directory / stale-socket handling

    private func prepareDirectories() throws {
        let parent = (socketPath as NSString).deletingLastPathComponent
        let grand = (parent as NSString).deletingLastPathComponent
        var created: Set<String> = []
        // Create any missing ancestors, each 0700.
        var missing: [String] = []
        var cur = parent
        var st = stat()
        while cur != "/" && !cur.isEmpty && lstat(cur, &st) != 0 && errno == ENOENT {
            missing.append(cur)
            cur = (cur as NSString).deletingLastPathComponent
        }
        for dir in missing.reversed() {
            if mkdir(dir, 0o700) != 0 && errno != EEXIST { throw AgentServerError.posix("mkdir \(dir)", errno) }
            created.insert(dir)
        }
        var toVerify = [parent]
        if (grand as NSString).lastPathComponent == ".atoll" || created.contains(grand) { toVerify.insert(grand, at: 0) }
        for dir in toVerify {
            var s = stat()
            guard lstat(dir, &s) == 0 else { throw AgentServerError.posix("stat \(dir)", errno) }
            let isLink = (s.st_mode & S_IFMT) == S_IFLNK
            let isDir = (s.st_mode & S_IFMT) == S_IFDIR
            if let problem = AgentSocketServer.directoryProblem(path: dir, isDirectory: isDir, isSymlink: isLink, mode: s.st_mode, uid: s.st_uid, expectedUID: expectedUID) {
                throw AgentServerError.insecureDirectory(problem)
            }
        }
    }

    /// Unlinks a leftover socket only when it is a socket owned by us and nobody is listening on it.
    private func clearStaleSocket() throws {
        var st = stat()
        guard lstat(socketPath, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == expectedUID else { throw AgentServerError.pathOccupied(socketPath) }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw AgentServerError.posix("socket", errno) }
        defer { close(probe) }
        guard let made = AgentSocketServer.makeAddress(socketPath) else { throw AgentServerError.pathTooLong(socketPath.utf8.count) }
        var addr = made.0
        let len = made.1
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, len) } }
        if rc == 0 { throw AgentServerError.alreadyRunning }
        let e = errno
        guard e == ECONNREFUSED || e == ENOENT else { throw AgentServerError.posix("probe \(socketPath)", e) }
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

    /// uid of the connected peer (LOCAL_PEERCRED), nil on failure.
    static func peerUID(_ fd: Int32) -> uid_t? {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, solLocal, localPeerCred, &cred, &len) == 0, cred.cr_version == UInt32(XUCRED_VERSION) else { return nil }
        return cred.cr_uid
    }

    /// pid of the connected peer (diagnostics only).
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPid, &pid, &len) == 0 else { return nil }
        return pid
    }

    /// True once the peer has fully closed (not merely half-closed, which `nc` does after sending).
    static func peerGone(_ fd: Int32) -> Bool {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, solLocal, localPeerPid, &pid, &len) != 0 && errno == ENOTCONN { return true }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        if poll(&p, 1, 0) > 0, p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        return false
    }

    // MARK: Connections

    private final class Conn {
        enum State { case reading, pending(UUID), closed }
        let fd: Int32
        var buffer = Data()
        var state: State = .reading
        var readSource: DispatchSourceRead?
        var deadline: DispatchSourceTimer?
        var sourceCancelled = false
        var closeRequested = false
        var fdClosed = false
        init(fd: Int32) { self.fd = fd }
        var id: ObjectIdentifier { ObjectIdentifier(self) }
        func tryClose() {
            if sourceCancelled && closeRequested && !fdClosed { fdClosed = true; Darwin.close(fd) }
        }
    }

    private final class ConnResponder: ApprovalResponder {
        weak var server: AgentSocketServer?
        let conn: Conn
        var done = false
        init(server: AgentSocketServer, conn: Conn) { self.server = server; self.conn = conn }
        func finish(writing data: Data?) {
            guard !done else { return }
            done = true
            if let d = data, !d.isEmpty { server?.writeAll(conn, d) }
            server?.requestClose(conn)
        }
    }

    private func acceptReady() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { return }            // EAGAIN (or listener closed)
            handleNew(cfd)
        }
    }

    private func handleNew(_ cfd: Int32) {
        AgentSocketServer.configure(cfd)
        guard let uid = AgentSocketServer.peerUID(cfd), AgentSocketServer.isAllowedPeer(uid: uid, expected: allowedPeerUID) else {
            stats.rejectedPeer += 1; Darwin.close(cfd); return
        }
        guard conns.count < limits.maxConnections else { stats.rejectedCap += 1; Darwin.close(cfd); return }
        stats.accepted += 1
        let c = Conn(fd: cfd)
        c.buffer.reserveCapacity(4096)
        conns[c.id] = c

        let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: queue)
        src.setEventHandler { [weak self, weak c] in
            guard let self = self, let c = c else { return }
            self.readable(c)
        }
        // Strong capture on purpose: the fd must be closed even after the connection was dropped from `conns`.
        // The handler (and with it this reference) is released by GCD once the source is cancelled.
        src.setCancelHandler {
            c.sourceCancelled = true
            c.tryClose()
        }
        c.readSource = src
        src.resume()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + limits.readDeadline, leeway: .milliseconds(20))
        t.setEventHandler { [weak self, weak c] in
            guard let self = self, let c = c else { return }
            if case .reading = c.state {
                self.stats.timedOut += 1
                // A client that never half-closes may still have sent a complete payload.
                if c.buffer.isEmpty { self.drop(c) } else { self.complete(c, lenient: true) }
            }
        }
        c.deadline = t
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
                if c.buffer.count > limits.maxBytes { stats.tooLarge += 1; drop(c); return }
                continue
            }
            if n == 0 { complete(c, lenient: false); return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            drop(c); return
        }
    }

    /// Stops reading (the payload is complete) and processes it.
    private func complete(_ c: Conn, lenient: Bool) {
        c.deadline?.cancel(); c.deadline = nil
        c.readSource?.cancel()
        guard process(c) else { stats.malformed += 1; requestClose(c); return }
    }

    private func drop(_ c: Conn) { requestClose(c) }

    /// Returns false when the payload is malformed (connection is then closed by the caller).
    private func process(_ c: Conn) -> Bool {
        let data = c.buffer
        guard let nl = data.firstIndex(of: 0x0A), nl <= 4096,
              let env = AgentEventDecoder.parseEnvelope(data.subdata(in: data.startIndex..<nl)) else { return false }
        let body = data.subdata(in: data.index(after: nl)..<data.endIndex)
        guard let obj = JSONField.parseObject(body), let ev = AgentEventDecoder.decode(envelope: env, body: obj) else { return false }
        c.buffer = Data()
        stats.events += 1
        onEvent?(ev)
        if case .permissionRequest(let info) = ev.payload {
            let responder = ConnResponder(server: self, conn: c)
            if let approval = broker.add(sessionKey: ev.key, kind: ev.kind, agentID: ev.agentID, info: info, responder: responder) {
                c.state = .pending(approval.id)
                stats.approvals += 1
                startWatching()
            } else {
                requestClose(c)          // cap reached: the agent asks in its own prompt
            }
        } else {
            requestClose(c)              // no reply, ever
        }
        return true
    }

    private func requestClose(_ c: Conn) {
        if case .closed = c.state, c.closeRequested { return }
        c.state = .closed
        c.closeRequested = true
        conns.removeValue(forKey: c.id)
        c.deadline?.cancel(); c.deadline = nil
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

    // MARK: Disconnect watching (only while approvals are pending)

    private func startWatching() {
        guard watchTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.watchTick() }
        watchTimer = t
        t.resume()
    }

    private func watchTick() {
        var anyPending = false
        for c in Array(conns.values) {
            guard case .pending(let id) = c.state else { continue }
            if AgentSocketServer.peerGone(c.fd) {
                broker.abort(id, reason: .clientDisconnected)
            } else { anyPending = true }
        }
        if !anyPending { watchTimer?.cancel(); watchTimer = nil }
    }

    // MARK: Decisions

    func decide(_ id: UUID, _ decision: ApprovalDecision) { broker.decide(id, decision) }
}
