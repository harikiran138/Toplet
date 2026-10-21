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

// MARK: Harness

final class SrvHarness {
    let dir: String
    let path: String
    let server: AgentSocketServer
    private let lock = NSLock()
    private var _events: [AgentEvent] = []
    private var _changes: [ApprovalBroker.Change] = []

    var events: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    var changes: [ApprovalBroker.Change] { lock.lock(); defer { lock.unlock() }; return _changes }

    init(limits: AgentSocketServer.Limits = AgentSocketServer.Limits(), allowedPeerUID: uid_t? = nil, name: String = "s") {
        dir = makeTmp(name)
        path = dir + "/run/agent.sock"
        server = AgentSocketServer(socketPath: path, limits: limits, allowedPeerUID: allowedPeerUID)
        server.onEvent = { [unowned self] e in self.lock.lock(); self._events.append(e); self.lock.unlock() }
        server.broker.onChange = { [unowned self] c in self.lock.lock(); self._changes.append(c); self.lock.unlock() }
    }

    var added: [PendingApproval] { changes.compactMap { if case .added(let a) = $0 { return a }; return nil } }
    var removed: [(UUID, ApprovalBroker.Closure)] { changes.compactMap { if case .removed(let id, _, let c) = $0 { return (id, c) }; return nil } }
}

/// Raw unix-socket client (for malformed/partial/oversized/idle connections that `nc` cannot express).
final class RawClient {
    let fd: Int32
    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, let (addr0, len) = AgentSocketServer.makeAddress(path) else { return nil }
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
}

private func claudeJSON(_ event: String, _ extra: [String: Any] = [:]) -> String { jsonString(Fx.claude(event, extra)) }
private func decisionOf(_ stdout: String) -> [String: Any]? {
    guard let o = jsonObject(stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
          let h = o["hookSpecificOutput"] as? [String: Any], (h["hookEventName"] as? String) == "PermissionRequest" else { return nil }
    return h["decision"] as? [String: Any]
}

private let permBash = claudeJSON("PermissionRequest", [
    "tool_name": "Bash", "tool_input": ["command": "npm test", "description": "Run tests"],
    "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]], "behavior": "allow", "destination": "localSettings"]],
])

func runServerTests() async {
    section("Socket server: setup, permissions, refusals")
    do {
        let h = SrvHarness()
        try h.server.start()
        var st = stat()
        check(lstat(h.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK, "socket file exists")
        eq(Int(st.st_mode & 0o777), 0o600, "socket is mode 0600")
        eq(st.st_uid, geteuid(), "socket is owned by us")
        var dst = stat()
        check(lstat(h.dir + "/run", &dst) == 0 && (dst.st_mode & 0o777) == 0o700, "created run directory is 0700")
        check(h.server.isRunning, "isRunning")
        try h.server.start()
        check(h.server.isRunning, "start() is idempotent")
        h.server.stop()
        check(!FileManager.default.fileExists(atPath: h.path), "stop removes the socket file")
        check(!h.server.isRunning, "stop clears isRunning")
        h.server.stop()
        check(true, "stop() is idempotent")
    } catch { check(false, "server setup threw \(error)") }

    do {   // default path shape
        let p = AgentSocketServer.defaultSocketPath(home: "/Users/someone")
        eq(p, "/Users/someone/.atoll/run/agent.sock", "default socket path")
        check(p.utf8.count <= AgentSocketServer.maxPathBytes, "default socket path is short enough for sun_path")
        let real = AgentSocketServer.defaultSocketPath()
        check(real.utf8.count <= AgentSocketServer.maxPathBytes, "default socket path for this user fits sun_path (\(real.utf8.count) bytes)")
    }

    do {   // path too long
        let long = makeTmp("L") + "/" + String(repeating: "d", count: 110) + "/agent.sock"
        let s = AgentSocketServer(socketPath: long)
        do { try s.start(); check(false, "too-long path must be refused") }
        catch let e as AgentServerError { check({ if case .pathTooLong = e { return true }; return false }(), "path longer than sun_path is refused") }
        catch { check(false, "wrong error \(error)") }
        check(AgentSocketServer.makeAddress(String(repeating: "a", count: 103)) != nil, "103-byte path fits")
        check(AgentSocketServer.makeAddress(String(repeating: "a", count: 104)) == nil, "104-byte path does not fit")
    }

    do {   // insecure directory (0755) is refused; secure one works
        let base = makeTmp("D")
        mkdir(base + "/open", 0o755); chmod(base + "/open", 0o755)
        let s = AgentSocketServer(socketPath: base + "/open/a.sock")
        do { try s.start(); check(false, "0755 directory must be refused") }
        catch let e as AgentServerError { check({ if case .insecureDirectory = e { return true }; return false }(), "directory with mode 0755 is refused") }
        catch { check(false, "wrong error \(error)") }
        check(!FileManager.default.fileExists(atPath: base + "/open/a.sock"), "no socket was created in the insecure directory")
        eq(Int((try? FileManager.default.attributesOfItem(atPath: base + "/open")[.posixPermissions] as? NSNumber)?.intValue ?? 0), 0o755, "the directory mode was not silently changed")
        // symlinked directory
        mkdir(base + "/real", 0o700)
        symlink(base + "/real", base + "/link")
        let s2 = AgentSocketServer(socketPath: base + "/link/a.sock")
        do { try s2.start(); check(false, "symlinked directory must be refused") }
        catch let e as AgentServerError { check({ if case .insecureDirectory = e { return true }; return false }(), "symlinked directory is refused") }
        catch { check(false, "wrong error \(error)") }
        // pure checks for ownership
        check(AgentSocketServer.directoryProblem(path: "/x", isDirectory: true, isSymlink: false, mode: 0o40700, uid: 501, expectedUID: 501) == nil, "directoryProblem: ours and 0700 is fine")
        check(AgentSocketServer.directoryProblem(path: "/x", isDirectory: true, isSymlink: false, mode: 0o40700, uid: 0, expectedUID: 501) != nil, "directoryProblem: foreign owner refused")
        check(AgentSocketServer.directoryProblem(path: "/x", isDirectory: true, isSymlink: false, mode: 0o40770, uid: 501, expectedUID: 501) != nil, "directoryProblem: group-accessible refused")
        check(AgentSocketServer.directoryProblem(path: "/x", isDirectory: true, isSymlink: false, mode: 0o40707, uid: 501, expectedUID: 501) != nil, "directoryProblem: world-accessible refused")
        check(AgentSocketServer.directoryProblem(path: "/x", isDirectory: false, isSymlink: false, mode: 0o100600, uid: 501, expectedUID: 501) != nil, "directoryProblem: a file is not a directory")
        check(AgentSocketServer.directoryProblem(path: "/x", isDirectory: false, isSymlink: true, mode: 0o120700, uid: 501, expectedUID: 501) != nil, "directoryProblem: symlink refused")
    }

    do {   // peer uid check
        check(AgentSocketServer.isAllowedPeer(uid: 501, expected: 501), "isAllowedPeer: same uid")
        check(!AgentSocketServer.isAllowedPeer(uid: 502, expected: 501), "isAllowedPeer: different uid rejected")
        check(!AgentSocketServer.isAllowedPeer(uid: 0, expected: 501), "isAllowedPeer: root is not special-cased")
        var fds: [Int32] = [0, 0]
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair for the peer-credential test")
        eq(AgentSocketServer.peerUID(fds[0]) ?? 0, geteuid(), "LOCAL_PEERCRED reports our uid on a unix socket pair")
        close(fds[0]); close(fds[1])
        // A server that only accepts another uid rejects every connection from us (stand-in for a foreign peer).
        let h = SrvHarness(allowedPeerUID: geteuid() &+ 1, name: "u")
        try h.server.start()
        let r = await sh(hookCommand(socket: h.path, blocking: false), stdin: claudeJSON("Stop"))
        eq(r.stdout, "", "a peer with the wrong uid gets nothing")
        check(await waitUntil { h.server.currentStats.rejectedPeer >= 1 }, "the wrong-uid peer is counted as rejected")
        await sleepMs(200)
        eq(h.events.count, 0, "events from a wrong-uid peer never reach the reducer")
        let r2 = await sh(hookCommand(socket: h.path, blocking: true), stdin: permBash)
        eq(r2.stdout, "", "a wrong-uid PermissionRequest is not held open")
        eq(h.server.pendingCount, 0, "...and creates no pending approval")
        h.server.stop()
    } catch { check(false, "peer uid harness: \(error)") }

    section("Socket server: non-blocking events through real /usr/bin/nc")
    let hs = SrvHarness()
    do { try hs.server.start() } catch { check(false, "start failed: \(error)"); return }
    let t0 = Date()
    let r1 = await sh(hookCommand(socket: hs.path, blocking: false), stdin: claudeJSON("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "echo hi"], "tool_use_id": "tu1"]))
    check(Date().timeIntervalSince(t0) < 2.0, "non-blocking hook round trip is fast")
    eq(r1.status, 0, "hook command exits 0")
    eq(r1.stdout, "", "non-blocking event gets an EMPTY reply")
    check(await waitUntil { hs.events.count == 1 }, "event reached the server")
    if let e = hs.events.first {
        eq(e.sessionID, Fx.sid, "event: session id"); eq(e.kind, .claudeCode, "event: kind")
        eq(e.pid ?? 0, getpid(), "event: ppid from $PPID is the hook's parent")
        if case .toolStart(let t) = e.payload { eq(t.summary, "echo hi", "event: tool summary") } else { check(false, "event payload") }
    }
    for name in ["UserPromptSubmit", "SessionStart", "Stop", "Notification", "SessionEnd"] {
        let extra: [String: Any] = name == "UserPromptSubmit" ? ["prompt": "hello"] : [:]
        let r = await sh(hookCommand(socket: hs.path, blocking: false), stdin: claudeJSON(name, extra))
        eq(r.stdout, "", "\(name): reply is empty (stray text would be injected into Claude's context)")
    }
    // Even the blocking-style command (no -w) must get nothing back for a non-permission event.
    let rb = await sh(hookCommand(socket: hs.path, blocking: true), stdin: claudeJSON("UserPromptSubmit", ["prompt": "x"]))
    eq(rb.stdout, "", "UserPromptSubmit through the blocking command: still empty"); eq(rb.status, 0, "...and exit 0")
    let rc = await sh(hookCommand(socket: hs.path, agent: "codex", blocking: false), stdin: jsonString(Fx.codex("UserPromptSubmit", ["prompt": "p"])))
    eq(rc.stdout, "", "codex event: empty reply")
    check(await waitUntil { hs.events.contains(where: { $0.kind == .codex }) }, "codex event reached the server")
    eq(hs.server.connectionCount, 0, "connections are closed after non-blocking events")
    eq(hs.server.pendingCount, 0, "no pending approvals from non-blocking events")

    section("Socket server: blocking permission (allow, deny, always, terminal, timeout, disconnect, stop)")
    // allow
    let perm = Task { await sh(hookCommand(socket: hs.path, blocking: true), stdin: permBash) }
    check(await waitUntil { hs.server.pendingCount == 1 }, "PermissionRequest creates a pending approval")
    check(hs.events.contains { if case .permissionRequest = $0.payload { return true }; return false }, "...and an event for the reducer")
    guard let p1 = hs.added.last else { check(false, "no pending approval recorded"); return }
    eq(p1.tool, "Bash", "pending: tool"); eq(p1.summary, "npm test", "pending: summary"); check(p1.detail != nil, "pending: detail")
    eq(p1.sessionKey, SessionKey(kind: .claudeCode, id: Fx.sid), "pending: session key")
    eq(p1.suggestions.map { $0.label }, ["Always allow Bash(npm test:*)"], "pending: suggestion labels")
    check(p1.expiresAt > p1.createdAt, "pending: expiry is after creation")
    check(p1.id.uuidString != Fx.sid, "pending id is server-generated")
    await sleepMs(300)
    check(!perm.isCancelled, "the hook is still waiting (connection held open)")
    hs.server.decide(p1.id, .allowOnce)
    let ra = await perm.value
    eq(ra.status, 0, "allow: exit 0")
    eq(decisionOf(ra.stdout)?["behavior"] as? String ?? "", "allow", "allow: hookSpecificOutput.decision.behavior == allow")
    check(decisionOf(ra.stdout)?["updatedPermissions"] == nil, "allow once carries no updatedPermissions")
    check(jsonObject(ra.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) != nil && ra.stdout.hasPrefix("{"), "allow: stdout is exactly one JSON object")
    check(await waitUntil { hs.removed.contains(where: { $0.0 == p1.id && $0.1 == .allowed }) }, "broker reports the approval closed as allowed")
    eq(hs.server.pendingCount, 0, "pending is removed after the decision")
    hs.server.decide(p1.id, .deny(message: "late"))
    check(true, "deciding an already-answered id is ignored")
    hs.server.decide(UUID(), .allowOnce)
    check(true, "deciding an unknown id is ignored")

    // deny
    let permD = Task { await sh(hookCommand(socket: hs.path, blocking: true), stdin: permBash) }
    check(await waitUntil { hs.server.pendingCount == 1 }, "second request pending")
    hs.server.decide(hs.added.last!.id, .deny(message: "No \u{202E}way\nplease"))
    let rd = await permD.value
    let dd = decisionOf(rd.stdout)
    eq(dd?["behavior"] as? String ?? "", "deny", "deny: behavior")
    eq(dd?["message"] as? String ?? "", "No way please", "deny: message is sanitised")
    let permD2 = Task { await sh(hookCommand(socket: hs.path, blocking: true), stdin: permBash) }
    check(await waitUntil { hs.server.pendingCount == 1 }, "third request pending")
    hs.server.decide(hs.added.last!.id, .deny(message: nil))
    let rd2 = await permD2.value
    check(((decisionOf(rd2.stdout)?["message"] as? String) ?? "").contains("denied"), "deny without a message gets a default message")

    // allowAlways
    let permA = Task { await sh(hookCommand(socket: hs.path, blocking: true), stdin: permBash) }
    check(await waitUntil { hs.server.pendingCount == 1 }, "request pending for allowAlways")
    hs.server.decide(hs.added.last!.id, .allowAlways(suggestionIndex: 0))
    let rA = await permA.value
    let da = decisionOf(rA.stdout)
    eq(da?["behavior"] as? String ?? "", "allow", "allowAlways: behavior allow")
    let up = da?["updatedPermissions"] as? [[String: Any]]
    eq(up?.count ?? 0, 1, "allowAlways: one updatedPermissions entry")
    eq(up?.first?["type"] as? String ?? "", "addRules", "allowAlways: built from the agent's own suggestion (type)")
    eq(((up?.first?["rules"] as? [[String: Any]])?.first?["ruleContent"] as? String) ?? "", "npm test:*", "allowAlways: built from the agent's own suggestion (rule)")
    eq(up?.first?["destination"] as? String ?? "", "localSettings", "allowAlways: destination preserved")
    // allowAlways with a bad index writes nothing
    let permB = Task { await sh(hookCommand(socket: hs.path, blocking: true), stdin: permBash) }
    check(await waitUntil { hs.server.pendingCount == 1 }, "request pending for bad index")
    let badID = hs.added.last!.id
    hs.server.decide(badID, .allowAlways(suggestionIndex: 7))
    let rB = await permB.value
    eq(rB.stdout, "", "allowAlways with an out-of-range index writes nothing (terminal decides)")
    check(await waitUntil { hs.removed.contains(where: { $0.0 == badID && $0.1 == .invalid }) }, "...and is reported as invalid")

    // letTerminalDecide
    let permT = Task { await sh(hookCommand(socket: hs.path, blocking: true), stdin: permBash) }
    check(await waitUntil { hs.server.pendingCount == 1 }, "request pending for letTerminalDecide")
    let tid = hs.added.last!.id
    hs.server.decide(tid, .letTerminalDecide)
    let rT = await permT.value
    eq(rT.stdout, "", "letTerminalDecide: nothing is written"); eq(rT.status, 0, "letTerminalDecide: hook exits 0")
    check(await waitUntil { hs.removed.contains(where: { $0.0 == tid && $0.1 == .terminal }) }, "letTerminalDecide is reported")

    // server-side cancel (session moved on)
    let permC = Task { await sh(hookCommand(socket: hs.path, blocking: true), stdin: permBash) }
    check(await waitUntil { hs.server.pendingCount == 1 }, "request pending for cancel")
    hs.server.broker.cancel(session: SessionKey(kind: .claudeCode, id: Fx.sid))
    let rC = await permC.value
    eq(rC.stdout, "", "cancel(session:) closes with no reply")

    // two requests with the same client-supplied tool_use_id are independent (no overwrite, no leak)
    let dup1 = Task { await sh(hookCommand(socket: hs.path, blocking: true), stdin: claudeJSON("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "a"], "tool_use_id": "SAME"])) }
    let dup2 = Task { await sh(hookCommand(socket: hs.path, blocking: true), stdin: claudeJSON("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "b"], "tool_use_id": "SAME"])) }
    check(await waitUntil { hs.server.pendingCount == 2 }, "identical client-supplied ids do not collide: two pending approvals")
    let ids = hs.server.broker.pendingIDs
    check(Set(ids).count == 2, "...with distinct server-generated ids")
    hs.server.decide(ids[0], .allowOnce); hs.server.decide(ids[1], .deny(message: nil))
    let d1 = await dup1.value, d2 = await dup2.value
    check(Set([decisionOf(d1.stdout)?["behavior"] as? String ?? "", decisionOf(d2.stdout)?["behavior"] as? String ?? ""]) == Set(["allow", "deny"]), "each connection receives only its own decision")

    // Codex
    let cxPerm = jsonString(Fx.codex("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build", "description": "Remove"], "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash"]], "behavior": "allow"]]]))
    let cx1 = Task { await sh(hookCommand(socket: hs.path, agent: "codex", blocking: true), stdin: cxPerm) }
    check(await waitUntil { hs.server.pendingCount == 1 }, "codex request pending")
    let cxP = hs.added.last!
    eq(cxP.sessionKey, SessionKey(kind: .codex, id: Fx.codexSID), "codex pending: key"); eq(cxP.suggestions.count, 0, "codex pending: client suggestions ignored")
    hs.server.decide(cxP.id, .allowOnce)
    eq(decisionOf((await cx1.value).stdout)?["behavior"] as? String ?? "", "allow", "codex allow")
    let cx2 = Task { await sh(hookCommand(socket: hs.path, agent: "codex", blocking: true), stdin: cxPerm) }
    check(await waitUntil { hs.server.pendingCount == 1 }, "codex request pending (deny)")
    hs.server.decide(hs.added.last!.id, .deny(message: "nope"))
    let cx2r = decisionOf((await cx2.value).stdout)
    eq(cx2r?["behavior"] as? String ?? "", "deny", "codex deny"); eq(cx2r?["message"] as? String ?? "", "nope", "codex deny: message")
    let cx3 = Task { await sh(hookCommand(socket: hs.path, agent: "codex", blocking: true), stdin: cxPerm) }
    check(await waitUntil { hs.server.pendingCount == 1 }, "codex request pending (always)")
    hs.server.decide(hs.added.last!.id, .allowAlways(suggestionIndex: 0))
    eq((await cx3.value).stdout, "", "codex allowAlways is unsupported: nothing written (updatedPermissions would fail closed)")

    // Pure decision JSON
    let allowJ = ApprovalBroker.decisionJSON(kind: .claudeCode, decision: .allowOnce, entries: [])
    eq(String(decoding: allowJ ?? Data(), as: UTF8.self), "{\"hookSpecificOutput\":{\"decision\":{\"behavior\":\"allow\"},\"hookEventName\":\"PermissionRequest\"}}", "decisionJSON: exact allow bytes")
    check(ApprovalBroker.decisionJSON(kind: .claudeCode, decision: .letTerminalDecide, entries: []) == nil, "decisionJSON: terminal = nil")
    let evil = Data("{\"type\":\"addRules\"}".utf8)
    check(ApprovalBroker.decisionJSON(kind: .claudeCode, decision: .allowAlways(suggestionIndex: -1), entries: [evil]) == nil, "decisionJSON: negative index = nil")
    check(ApprovalBroker.decisionJSON(kind: .claudeCode, decision: .allowAlways(suggestionIndex: 0), entries: [Data()]) == nil, "decisionJSON: a suggestion that was not offered = nil")
    check(ApprovalBroker.decisionJSON(kind: .codex, decision: .allowAlways(suggestionIndex: 0), entries: [evil]) == nil, "decisionJSON: codex allowAlways = nil")
    let longMsg = ApprovalBroker.decisionJSON(kind: .claudeCode, decision: .deny(message: String(repeating: "m", count: 10_000)), entries: [])
    check((longMsg?.count ?? 99999) < 1200, "decisionJSON: deny message is bounded")

    // Timeout / disconnect / stop use their own harnesses
    section("Socket server: timeout, client disconnect, server stop while pending")
    do {
        var lim = AgentSocketServer.Limits(); lim.approvalTimeout = 0.5
        let h = SrvHarness(limits: lim, name: "to")
        try h.server.start()
        let t = Date()
        let r = await sh(hookCommand(socket: h.path, blocking: true), stdin: permBash)
        let dt = Date().timeIntervalSince(t)
        eq(r.stdout, "", "timeout: nothing is written"); eq(r.status, 0, "timeout: hook exits 0")
        check(dt > 0.4 && dt < 3.0, "timeout fires after the configured time (\(String(format: "%.2f", dt)) s)")
        check(await waitUntil { h.removed.contains(where: { $0.1 == .timedOut }) }, "timeout is reported by the broker")
        eq(h.server.pendingCount, 0, "pending is gone after the timeout")
        h.server.stop()
    } catch { check(false, "timeout harness: \(error)") }

    do {   // client disconnect first
        let h = SrvHarness(name: "dc")
        try h.server.start()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        p.arguments = ["-U", h.path]
        let inP = Pipe(), outP = Pipe()
        p.standardInput = inP; p.standardOutput = outP; p.standardError = FileHandle.nullDevice
        try p.run()
        try inP.fileHandleForWriting.write(contentsOf: Data(("{\"v\":1,\"agent\":\"claude\",\"ppid\":1234}\n" + permBash).utf8))
        try inP.fileHandleForWriting.close()
        check(await waitUntil { h.server.pendingCount == 1 }, "disconnect: request is pending")
        p.terminate()
        check(await waitUntil(3) { h.server.pendingCount == 0 }, "client disconnect removes the pending approval")
        check(h.removed.contains(where: { $0.1 == .clientDisconnected }), "...reported as clientDisconnected")
        eq(h.server.connectionCount, 0, "...and the connection is released")
        let id = h.added.last!.id
        h.server.decide(id, .allowOnce)
        check(true, "deciding after a disconnect is a harmless no-op")
        h.server.stop()
    } catch { check(false, "disconnect harness: \(error)") }

    do {   // server stop while pending
        let h = SrvHarness(name: "st")
        try h.server.start()
        let t = Task { await sh(hookCommand(socket: h.path, blocking: true), stdin: permBash) }
        check(await waitUntil { h.server.pendingCount == 1 }, "stop: request pending")
        let started = Date()
        h.server.stop()
        let r = await t.value
        eq(r.stdout, "", "server stop while pending: empty output (agent falls back to its own prompt)")
        eq(r.status, 0, "server stop while pending: hook exits 0")
        check(Date().timeIntervalSince(started) < 3, "server stop releases the hook promptly")
        check(h.removed.contains(where: { $0.1 == .serverStopped }), "stop reported as serverStopped")
        check(!FileManager.default.fileExists(atPath: h.path), "socket file removed on stop")
        let r2 = await sh(hookCommand(socket: h.path, blocking: true), stdin: permBash)
        eq(r2.stdout, "", "after stop the hook command is a silent no-op"); eq(r2.status, 0, "...exit 0")
    } catch { check(false, "stop harness: \(error)") }

    section("Socket server: stale files, foreign files, second instance")
    do {
        // stale socket: a socket file with no listener
        let base = makeTmp("st")
        mkdir(base + "/run", 0o700)
        let path = base + "/run/agent.sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var (addr, len) = AgentSocketServer.makeAddress(path)!
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        close(fd)
        check(FileManager.default.fileExists(atPath: path), "stale socket file fixture exists")
        let rs = await sh(hookCommand(socket: path, blocking: true), stdin: permBash)
        eq(rs.stdout, "", "hook against a stale socket: no output"); eq(rs.status, 0, "hook against a stale socket: exit 0 (fail open)")
        let s = AgentSocketServer(socketPath: path)
        try s.start()
        check(s.isRunning, "a stale socket owned by us is replaced")
        // a second server on the same path must not steal it
        let s2 = AgentSocketServer(socketPath: path)
        do { try s2.start(); check(false, "second instance must be refused") }
        catch let e as AgentServerError { eq(e, AgentServerError.alreadyRunning, "a live listener is never replaced") }
        catch { check(false, "wrong error \(error)") }
        s.stop()
        // the file was not removed by the refused second instance
    } catch { check(false, "stale harness: \(error)") }

    do {   // a regular file at the path
        let base = makeTmp("rf")
        mkdir(base + "/run", 0o700)
        let path = base + "/run/agent.sock"
        write(path, "precious")
        let s = AgentSocketServer(socketPath: path)
        do { try s.start(); check(false, "regular file must be refused") }
        catch let e as AgentServerError { check({ if case .pathOccupied = e { return true }; return false }(), "a non-socket file at the path is refused") }
        catch { check(false, "wrong error \(error)") }
        eq((try? String(contentsOfFile: path, encoding: .utf8)) ?? "", "precious", "...and left untouched")
        // a symlink at the path is also not ours to delete
        let linkBase = makeTmp("sl")
        mkdir(linkBase + "/run", 0o700)
        write(linkBase + "/target", "t")
        symlink(linkBase + "/target", linkBase + "/run/agent.sock")
        let s2 = AgentSocketServer(socketPath: linkBase + "/run/agent.sock")
        do { try s2.start(); check(false, "symlink must be refused") } catch { check(true, "a symlink at the socket path is refused") }
        check(FileManager.default.fileExists(atPath: linkBase + "/target"), "...its target is untouched")
    }

    do {   // stop does not delete a replaced file
        let h = SrvHarness(name: "rp")
        try h.server.start()
        unlink(h.path)
        write(h.path, "someone else's file")
        h.server.stop()
        check(FileManager.default.fileExists(atPath: h.path), "stop() only unlinks the socket it created")
    } catch { check(false, "replace harness: \(error)") }

    section("Socket server: malformed, oversized, partial, idle connections")
    do {
        var lim = AgentSocketServer.Limits(); lim.readDeadline = 0.4
        let h = SrvHarness(limits: lim, name: "mf")
        try h.server.start()
        func good() async -> Bool {
            _ = await sh(hookCommand(socket: h.path, blocking: false), stdin: claudeJSON("Stop", ["last_assistant_message": "ok"]))
            return await waitUntil { h.events.contains { if case .stop = $0.payload { return true }; return false } }
        }
        // garbage
        for (name, payload) in [("garbage", "garbage without a newline"), ("bad json", "{\"v\":1,\"agent\":\"claude\"}\n{not json"), ("no envelope", "{\"hook_event_name\":\"Stop\",\"session_id\":\"s\"}\n"),
                                ("envelope only", "{\"v\":1,\"agent\":\"claude\",\"ppid\":5}\n"), ("wrong agent", "{\"v\":1,\"agent\":\"evil\"}\n{\"hook_event_name\":\"Stop\",\"session_id\":\"s\"}"),
                                ("truncated json", "{\"v\":1,\"agent\":\"claude\"}\n" + String(claudeJSON("Stop").prefix(40))), ("array body", "{\"v\":1,\"agent\":\"claude\"}\n[1,2,3]"),
                                ("binary", String(decoding: [0, 255, 254, 1, 2, 3, 10, 0, 0], as: UTF8.self))] {
            let r = await sh(hookCommand(socket: h.path, blocking: false), stdin: payload)
            eq(r.stdout, "", "malformed (\(name)): empty reply, no crash")
        }
        // The shell hook adds its own envelope line, so also send these raw (no extra framing).
        for (name, payload) in [("raw garbage", "zzzz\n{}"), ("raw bad json", "{\"v\":1,\"agent\":\"claude\"}\n{{{{")] {
            if let c = RawClient(path: h.path) { c.send(payload); c.shutdownWrite(); let (d, eof) = c.readAll(timeout: 1.5); check(d.isEmpty && eof, "raw \(name): closed with no reply"); c.closeNow() }
            else { check(false, "raw client could not connect") }
        }
        check(h.server.currentStats.malformed >= 5, "malformed payloads are counted (\(h.server.currentStats.malformed))")
        check(await good(), "the server still works after malformed input")
        // oversized (2 MiB)
        let big = String(repeating: "A", count: 2 << 20)
        if let c = RawClient(path: h.path) {
            c.send("{\"v\":1,\"agent\":\"claude\"}\n{\"hook_event_name\":\"Stop\",\"session_id\":\"big\",\"x\":\"" + big + "\"}")
            c.shutdownWrite()
            let (d, eof) = c.readAll(timeout: 3)
            check(d.isEmpty && eof, "oversized payload: closed with no reply"); c.closeNow()
        } else { check(false, "oversized: connect failed") }
        check(await waitUntil { h.server.currentStats.tooLarge >= 1 }, "oversized payload is counted")
        check(!h.events.contains(where: { $0.sessionID == "big" }), "oversized payload never reaches the reducer")
        // just under the cap is fine (truncated summary, but delivered)
        let nearCap = String(repeating: "B", count: 900_000)
        _ = await sh(hookCommand(socket: h.path, blocking: false), stdin: claudeJSON("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": nearCap], "session_id": "near"]), timeout: 20)
        check(await waitUntil(5) { h.events.contains(where: { $0.sessionID == "near" }) }, "a 900 KB payload (under the 1 MiB cap) is accepted")
        if let e = h.events.first(where: { $0.sessionID == "near" }), case .toolStart(let t) = e.payload { check(t.summary.count <= 160, "...and its summary is bounded") }
        // idle connection is dropped at the deadline
        if let c = RawClient(path: h.path) {
            let t = Date()
            let (d, eof) = c.readAll(timeout: 3)
            check(d.isEmpty && eof, "idle connection is closed by the read deadline")
            check(Date().timeIntervalSince(t) < 2.5, "...within a couple of seconds")
            c.closeNow()
        }
        // partial JSON, client never sends EOF: dropped at the deadline
        if let c = RawClient(path: h.path) {
            c.send("{\"v\":1,\"agent\":\"claude\"}\n{\"hook_event_name\":\"Sto")
            let (d, eof) = c.readAll(timeout: 3)
            check(d.isEmpty && eof, "partial payload without EOF is dropped at the deadline"); c.closeNow()
        }
        // complete payload but the client never half-closes: accepted at the deadline
        if let c = RawClient(path: h.path) {
            c.send("{\"v\":1,\"agent\":\"claude\"}\n" + claudeJSON("SessionStart", ["session_id": "nohalfclose"]))
            let (d, eof) = c.readAll(timeout: 3)
            check(d.isEmpty && eof, "complete payload without EOF: no reply, connection closed")
            check(await waitUntil { h.events.contains(where: { $0.sessionID == "nohalfclose" }) }, "...and the event is still delivered")
            c.closeNow()
        }
        // open and close immediately
        for _ in 0..<20 { if let c = RawClient(path: h.path) { c.closeNow() } }
        check(await good(), "20 instant connect/disconnects leave the server healthy")
        check(await waitUntil { h.server.connectionCount == 0 }, "no connection leak after abusive clients (\(h.server.connectionCount))")
        h.server.stop()
    } catch { check(false, "malformed harness: \(error)") }

    section("Socket server: concurrency and caps")
    do {
        let h = SrvHarness(name: "cc")
        try h.server.start()
        var tasks: [Task<ShellResult, Never>] = []
        for i in 0..<64 {
            let payload = claudeJSON("PreToolUse", ["session_id": "c\(i)", "tool_name": "Bash", "tool_input": ["command": "echo \(i)"]])
            tasks.append(Task { await sh(hookCommand(socket: h.path, blocking: false), stdin: payload, timeout: 20) })
        }
        var empties = 0
        for t in tasks { if (await t.value).stdout.isEmpty { empties += 1 } }
        eq(empties, 64, "64 concurrent clients all complete with empty replies")
        check(await waitUntil(5) { h.events.count == 64 }, "all 64 events were delivered (\(h.events.count))")
        eq(Set(h.events.map { $0.sessionID }).count, 64, "...each once")
        eq(h.server.connectionCount, 0, "all connections are released")
        h.server.stop()
    } catch { check(false, "concurrency harness: \(error)") }

    do {   // connection cap
        var lim = AgentSocketServer.Limits(); lim.maxConnections = 8; lim.readDeadline = 5
        let h = SrvHarness(limits: lim, name: "cap")
        try h.server.start()
        var clients: [RawClient] = []
        for _ in 0..<14 { if let c = RawClient(path: h.path) { clients.append(c) } }
        check(await waitUntil { h.server.currentStats.accepted + h.server.currentStats.rejectedCap >= 14 }, "all 14 connect attempts were seen")
        check(h.server.connectionCount <= 8, "never more than maxConnections open (\(h.server.connectionCount))")
        check(h.server.currentStats.rejectedCap >= 6, "connections over the cap are rejected (\(h.server.currentStats.rejectedCap))")
        for c in clients { c.closeNow() }
        check(await waitUntil { h.server.connectionCount == 0 }, "caps are released when clients leave")
        h.server.stop()
    } catch { check(false, "cap harness: \(error)") }

    do {   // pending cap
        var lim = AgentSocketServer.Limits(); lim.maxPending = 2
        let h = SrvHarness(limits: lim, name: "pc")
        try h.server.start()
        let a = Task { await sh(hookCommand(socket: h.path, blocking: true), stdin: claudeJSON("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "1"]])) }
        let b = Task { await sh(hookCommand(socket: h.path, blocking: true), stdin: claudeJSON("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "2"]])) }
        check(await waitUntil { h.server.pendingCount == 2 }, "two approvals pending (the cap)")
        let c = await sh(hookCommand(socket: h.path, blocking: true), stdin: claudeJSON("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "3"]]), timeout: 5)
        eq(c.stdout, "", "a request over the pending cap gets no decision: the agent asks in its own prompt")
        eq(h.server.pendingCount, 2, "pending stays capped")
        check(h.events.filter { if case .permissionRequest = $0.payload { return true }; return false }.count == 3, "...but the session still sees the permission event")
        for id in h.server.broker.pendingIDs { h.server.decide(id, .letTerminalDecide) }
        _ = await a.value; _ = await b.value
        h.server.stop()
    } catch { check(false, "pending cap harness: \(error)") }
}
