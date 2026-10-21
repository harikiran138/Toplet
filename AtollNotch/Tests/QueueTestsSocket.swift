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

// T8: socket security and robustness of the `atoll-notify` ingress. Real sockets under /tmp/an-<pid>, never ~/.atoll.

final class IngHarness {
    let dir: String
    let path: String
    let server: NotificationIngressServer
    let received = Atomic<[NotchNotification]>([])
    let peers = Atomic<[IngressPeer]>([])
    let pendingReplies = Atomic<[(IngressReply) -> Void]>([])
    /// nil result = never answer (the test may answer later through `pendingReplies`).
    var respond: (NotchNotification) -> IngressReply? = { .ok(id: $0.id) }

    init(limits: NotificationIngressServer.Limits = NotificationIngressServer.Limits(), allowedPeerUID: uid_t? = nil, name: String = "s", clock: @escaping () -> Date = Date.init, withHandler: Bool = true) {
        dir = makeTmp(name)
        path = dir + "/.atoll/run/notify.sock"
        server = NotificationIngressServer(socketPath: path, limits: limits, allowedPeerUID: allowedPeerUID, clock: clock)
        if withHandler {
            server.onNotification = { [unowned self] n, peer, reply in
                self.received.mutate { $0.append(n) }
                self.peers.mutate { $0.append(peer) }
                if let r = self.respond(n) { reply(r) } else { self.pendingReplies.mutate { $0.append(reply) } }
            }
        }
    }
}

private func good(_ title: String = "T") -> String { "{\"v\":1,\"title\":\"\(title)\"}" }

func runSocketTests() async {
    let baselineFDs = socketFDCount()

    section("Ingress socket: setup, permissions, lifecycle")
    do {
        let h = IngHarness()
        try h.server.start()
        var st = stat()
        check(lstat(h.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK, "socket file exists")
        eq(Int(st.st_mode & 0o777), 0o600, "socket is mode 0600")
        eq(st.st_uid, geteuid(), "socket is owned by us")
        var dst = stat()
        check(lstat(h.dir + "/.atoll/run", &dst) == 0 && (dst.st_mode & 0o777) == 0o700, "created run directory is 0700")
        var gst = stat()
        check(lstat(h.dir + "/.atoll", &gst) == 0 && (gst.st_mode & 0o777) == 0o700, "created .atoll directory is 0700")
        check(h.server.isRunning, "isRunning")
        try h.server.start()
        check(h.server.isRunning, "start() is idempotent")
        let r = RawClient.request(path: h.path, good())
        check(r.reply?["ok"] as? Bool == true, "a valid request works after the double start")
        h.server.stop()
        check(!FileManager.default.fileExists(atPath: h.path), "stop removes the socket file")
        check(!h.server.isRunning, "stop clears isRunning")
        h.server.stop()
        check(true, "stop() is idempotent")
        check(RawClient(path: h.path) == nil, "nobody can connect after stop")
        try h.server.start()
        let r2 = RawClient.request(path: h.path, good())
        check(r2.reply?["ok"] as? Bool == true, "start after stop works (restart)")
        h.server.stop()
    } catch { check(false, "setup threw \(error)") }

    do {
        eq(NotificationIngressServer.defaultSocketPath(home: "/Users/someone"), "/Users/someone/.atoll/run/notify.sock", "default socket path")
        check(NotificationIngressServer.defaultSocketPath(home: "/Users/someone").utf8.count <= NotificationIngressServer.maxPathBytes, "default path fits sun_path")
        check(NotificationIngressServer.defaultSocketPath().utf8.count <= NotificationIngressServer.maxPathBytes, "default path for this user fits sun_path (\(NotificationIngressServer.defaultSocketPath().utf8.count) bytes)")
        let long = makeTmp("L") + "/" + String(repeating: "d", count: 110) + "/notify.sock"
        let s = NotificationIngressServer(socketPath: long)
        do { try s.start(); check(false, "too-long path must be refused") }
        catch let e as NotificationIngressError { check({ if case .pathTooLong = e { return true }; return false }(), "path longer than sun_path is refused") }
        catch { check(false, "wrong error \(error)") }
        check(NotificationIngressServer.makeAddress(String(repeating: "a", count: 103)) != nil, "103-byte path fits")
        check(NotificationIngressServer.makeAddress(String(repeating: "a", count: 104)) == nil, "104-byte path does not fit")
        let empty = NotificationIngressServer(socketPath: "")
        _ = empty
    }

    section("Ingress socket: directory and file hazards")
    do {
        let base = makeTmp("D")
        mkdir(base + "/open", 0o755); chmod(base + "/open", 0o755)
        let s = NotificationIngressServer(socketPath: base + "/open/n.sock")
        do { try s.start(); check(false, "0755 directory must be refused") }
        catch let e as NotificationIngressError { check({ if case .insecureDirectory = e { return true }; return false }(), "directory with mode 0755 is refused") }
        catch { check(false, "wrong error \(error)") }
        check(!FileManager.default.fileExists(atPath: base + "/open/n.sock"), "no socket is created in an insecure directory")
        eq(Int((try? FileManager.default.attributesOfItem(atPath: base + "/open")[.posixPermissions] as? NSNumber)?.intValue ?? 0), 0o755, "the directory mode is not silently changed")
        mkdir(base + "/real", 0o700)
        symlink(base + "/real", base + "/link")
        let s2 = NotificationIngressServer(socketPath: base + "/link/n.sock")
        do { try s2.start(); check(false, "symlinked directory must be refused") }
        catch let e as NotificationIngressError { check({ if case .insecureDirectory = e { return true }; return false }(), "symlinked directory is refused") }
        catch { check(false, "wrong error \(error)") }
        let dp = NotificationIngressServer.directoryProblem
        check(dp("/x", true, false, 0o40700, 501, 501) == nil, "directoryProblem: ours and 0700 is fine")
        check(dp("/x", true, false, 0o40700, 0, 501) != nil, "directoryProblem: foreign owner refused")
        check(dp("/x", true, false, 0o40770, 501, 501) != nil, "directoryProblem: group access refused")
        check(dp("/x", true, false, 0o40707, 501, 501) != nil, "directoryProblem: world access refused")
        check(dp("/x", false, false, 0o100600, 501, 501) != nil, "directoryProblem: a file is not a directory")
        check(dp("/x", false, true, 0o120700, 501, 501) != nil, "directoryProblem: symlink refused")
    } catch { check(false, "hazard harness: \(error)") }
    do {  // stale socket, live listener, regular file, symlink, replaced file
        let base = makeTmp("st")
        mkdir(base + "/run", 0o700)
        let path = base + "/run/n.sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var (addr, len) = NotificationIngressServer.makeAddress(path)!
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        close(fd)
        check(FileManager.default.fileExists(atPath: path), "stale socket fixture exists")
        let s = NotificationIngressServer(socketPath: path)
        try s.start()
        check(s.isRunning, "a stale socket owned by us is replaced")
        let s2 = NotificationIngressServer(socketPath: path)
        do { try s2.start(); check(false, "second instance must be refused") }
        catch let e as NotificationIngressError { eq(e, NotificationIngressError.alreadyRunning, "a live listener is never replaced") }
        catch { check(false, "wrong error \(error)") }
        s.stop()
        let b2 = makeTmp("rf")
        mkdir(b2 + "/run", 0o700)
        write(b2 + "/run/n.sock", "precious")
        let s3 = NotificationIngressServer(socketPath: b2 + "/run/n.sock")
        do { try s3.start(); check(false, "regular file must be refused") }
        catch let e as NotificationIngressError { check({ if case .pathOccupied = e { return true }; return false }(), "a non-socket file at the path is refused") }
        eq((try? String(contentsOfFile: b2 + "/run/n.sock", encoding: .utf8)) ?? "", "precious", "...and left untouched")
        let b3 = makeTmp("sl")
        mkdir(b3 + "/run", 0o700)
        write(b3 + "/target", "t")
        symlink(b3 + "/target", b3 + "/run/n.sock")
        let s4 = NotificationIngressServer(socketPath: b3 + "/run/n.sock")
        do { try s4.start(); check(false, "symlink must be refused") } catch { check(true, "a symlink at the socket path is refused") }
        check(FileManager.default.fileExists(atPath: b3 + "/target"), "...its target is untouched")
        let h = IngHarness(name: "rp")
        try h.server.start()
        unlink(h.path); write(h.path, "someone else's file")
        h.server.stop()
        check(FileManager.default.fileExists(atPath: h.path), "stop() only unlinks the socket it created")
    } catch { check(false, "stale harness: \(error)") }

    section("Ingress socket: peer identity")
    do {
        check(NotificationIngressServer.isAllowedPeer(uid: 501, expected: 501), "isAllowedPeer: same uid")
        check(!NotificationIngressServer.isAllowedPeer(uid: 502, expected: 501), "isAllowedPeer: another uid rejected")
        check(!NotificationIngressServer.isAllowedPeer(uid: 0, expected: 501), "isAllowedPeer: root is not special-cased")
        var fds: [Int32] = [0, 0]
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair for the credential test")
        eq(NotificationIngressServer.peerUID(fds[0]) ?? 0, geteuid(), "LOCAL_PEERCRED reports our uid")
        eq(NotificationIngressServer.peerPID(fds[0]) ?? 0, getpid(), "LOCAL_PEERPID reports our pid")
        close(fds[0]); close(fds[1])
        let h = IngHarness(allowedPeerUID: geteuid() &+ 1, name: "u")
        try h.server.start()
        let r = RawClient.request(path: h.path, good())
        check(r.reply == nil && r.raw.isEmpty, "a peer with the wrong uid gets nothing")
        check(await waitUntil { h.server.currentStats.rejectedPeer >= 1 }, "the wrong-uid peer is counted")
        eq(h.received.get().count, 0, "a wrong-uid request never reaches the handler")
        h.server.stop()
        let h2 = IngHarness(name: "p")
        try h2.server.start()
        _ = RawClient.request(path: h2.path, good())
        eq(h2.peers.get().first?.uid ?? 0, geteuid(), "the handler sees the peer uid")
        eq(h2.peers.get().first?.pid ?? 0, getpid(), "the handler sees the peer pid")
        h2.server.stop()
    } catch { check(false, "peer harness: \(error)") }

    section("Ingress socket: protocol, replies, handler contract")
    do {
        let h = IngHarness(name: "pr")
        try h.server.start()
        let r = RawClient.request(path: h.path, "{\"v\":1,\"title\":\"Hello\",\"body\":\"World\",\"app\":\"make\",\"priority\":\"high\"}")
        check(r.reply?["ok"] as? Bool == true, "valid request: ok:true")
        check(UUID(uuidString: r.reply?["id"] as? String ?? "") != nil, "valid request: reply carries a UUID id")
        check(r.eof && r.raw.hasSuffix("\n") && r.raw.filter { $0 == "\n" }.count == 1, "reply is a single line and the server closes")
        let n = h.received.get().first
        check(n?.title == "Hello" && n?.body == "World" && n?.source == .cli && n?.priority == .high, "handler received the decoded notification")
        eq(n?.appName ?? "", "make (via CLI)", "handler sees provenance in the app name")
        eq(r.reply?["id"] as? String ?? "", n?.id.uuidString ?? "x", "reply id is the notification id")
        h.respond = { _ in .error("rate limited") }
        let r2 = RawClient.request(path: h.path, good())
        check(r2.reply?["ok"] as? Bool == false && r2.reply?["error"] as? String == "rate limited", "handler error is relayed as ok:false")
        h.respond = { n in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { h.pendingReplies.get().last?(.ok(id: n.id)) }
            return nil
        }
        let r3 = RawClient.request(path: h.path, good("async"))
        check(r3.reply?["ok"] as? Bool == true, "the handler may reply later from another thread")
        h.respond = { n in
            h.pendingReplies.mutate { $0.removeAll() }
            return .ok(id: n.id)
        }
        h.server.stop()
        let h2 = IngHarness(name: "dbl")
        h2.server.onNotification = { n, _, reply in reply(.ok(id: n.id)); reply(.error("second")); reply(.error("third")) }
        try h2.server.start()
        let r4 = RawClient.request(path: h2.path, good())
        check(r4.reply?["ok"] as? Bool == true && r4.raw.filter { $0 == "\n" }.count == 1, "only the first reply counts")
        h2.server.stop()
        let h3 = IngHarness(name: "nh", withHandler: false)
        try h3.server.start()
        let r5 = RawClient.request(path: h3.path, good())
        check(r5.reply?["ok"] as? Bool == false, "no handler installed: rejected with a reply")
        h3.server.stop()
        var lim = NotificationIngressServer.Limits(); lim.replyDeadline = 0.3
        let h4 = IngHarness(limits: lim, name: "to")
        h4.respond = { _ in nil }
        try h4.server.start()
        let t = Date()
        let r6 = RawClient.request(path: h4.path, good())
        let dt = Date().timeIntervalSince(t)
        check(r6.reply?["error"] as? String == "timed out" && dt > 0.25 && dt < 2, "a handler that never answers is cut off at the reply deadline (\(String(format: "%.2f", dt)) s)")
        eq(h4.server.currentStats.replyTimeouts, 1, "reply timeout is counted")
        h4.pendingReplies.get().last?(.ok(id: UUID()))
        await sleepMs(100)
        check(h4.server.connectionCount == 0, "a late answer after the timeout is ignored and leaks nothing")
        h4.server.stop()
    } catch { check(false, "protocol harness: \(error)") }

    section("Ingress socket: malformed, oversized, slow-loris")
    do {
        var lim = NotificationIngressServer.Limits(); lim.readDeadline = 0.4
        let h = IngHarness(limits: lim, name: "mf")
        try h.server.start()
        for (name, payload, err) in [("garbage", "garbage without braces", "malformed JSON"), ("truncated", "{\"v\":1,\"title\":\"x", "malformed JSON"),
                                     ("no version", "{\"title\":\"x\"}", "unsupported protocol version (expected v:1)"), ("no title", "{\"v\":1}", "title is required"),
                                     ("array", "[1,2,3]", "malformed JSON"), ("bad url", "{\"v\":1,\"title\":\"x\",\"url\":\"javascript:alert(1)\"}", "invalid url"),
                                     ("binary", String(decoding: [0, 255, 254, 1, 2, 3, 10, 0, 0], as: UTF8.self), "malformed JSON")] {
            let r = RawClient.request(path: h.path, payload)
            check(r.reply?["ok"] as? Bool == false && r.reply?["error"] as? String == err, "malformed (\(name)): ok:false, \"\(err)\"")
        }
        let empty = RawClient.request(path: h.path, "")
        check(empty.reply?["ok"] as? Bool == false, "an empty request gets an error reply")
        eq(h.received.get().count, 0, "none of the malformed requests reached the handler")
        check(h.server.currentStats.malformed >= 7, "malformed requests are counted (\(h.server.currentStats.malformed))")
        let ok = RawClient.request(path: h.path, good())
        check(ok.reply?["ok"] as? Bool == true, "the server still works after malformed input")

        let big = String(repeating: "A", count: 2 << 20)
        if let c = RawClient(path: h.path) {
            c.send("{\"v\":1,\"title\":\"big\",\"body\":\"" + big + "\"}")
            c.shutdownWrite()
            let (d, eof) = c.readAll(timeout: 3)
            let s = String(decoding: d, as: UTF8.self)
            check(eof && !s.contains("\"ok\":true"), "2 MiB payload: connection closed, never accepted")
            c.closeNow()
        } else { check(false, "oversize: connect failed") }
        check(await waitUntil { h.server.currentStats.tooLarge >= 1 }, "oversized payload is counted")
        check(!h.received.get().contains { $0.title == "big" }, "oversized payload never reaches the handler")
        let near = String(repeating: "B", count: 900_000)
        let rn = RawClient.request(path: h.path, "{\"v\":1,\"title\":\"near\",\"body\":\"" + near + "\"}", timeout: 8)
        check(rn.reply?["ok"] as? Bool == true, "a 900 KB payload (under the 1 MiB cap) is accepted")
        check((h.received.get().first { $0.title == "near" }?.body?.count ?? 9999) <= 400, "...and its body is bounded to 400 graphemes")

        if let c = RawClient(path: h.path) {
            let t = Date()
            let (d, eof) = c.readAll(timeout: 3)
            check(d.isEmpty && eof, "idle connection (no bytes) is closed silently at the deadline")
            check(Date().timeIntervalSince(t) < 2.0, "...within the deadline window")
            c.closeNow()
        }
        if let c = RawClient(path: h.path) {
            c.send("{\"v\":1,\"title\":\"Sl")
            let t = Date()
            let (d, eof) = c.readAll(timeout: 3)
            let r = jsonObject(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            check(eof && r?["ok"] as? Bool == false, "partial payload without EOF is cut off at the deadline with an error")
            check(Date().timeIntervalSince(t) < 2.0, "...in under 2 s")
            c.closeNow()
        }
        if let c = RawClient(path: h.path) {
            c.send(good("nohalfclose"))
            let (d, eof) = c.readAll(timeout: 3)
            let r = jsonObject(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            check(eof && r?["ok"] as? Bool == true, "a complete payload without half-close is accepted at the deadline")
            check(h.received.get().contains { $0.title == "nohalfclose" }, "...and delivered")
            c.closeNow()
        }
        if let c = RawClient(path: h.path) {   // trickle: one byte every 100 ms
            let t = Date()
            let payload = Array("{\"v\":1,\"title\":\"trickle\"}".utf8)
            var sent = 0
            for b in payload { c.send(Data([b])); sent += 1; Thread.sleep(forTimeInterval: 0.1); if Date().timeIntervalSince(t) > 1.2 { break } }
            let (d, eof) = c.readAll(timeout: 2)
            check(eof, "a trickling client is dropped (sent \(sent) of \(payload.count) bytes)")
            check(!h.received.get().contains { $0.title == "trickle" }, "...and its partial request is not delivered")
            _ = d
            c.closeNow()
        }
        for _ in 0..<20 { if let c = RawClient(path: h.path) { c.closeNow() } }
        let again = RawClient.request(path: h.path, good())
        check(again.reply?["ok"] as? Bool == true, "20 instant connect/disconnects leave the server healthy")
        check(await waitUntil { h.server.connectionCount == 0 }, "no connection leak after abusive clients (\(h.server.connectionCount))")
        h.server.stop()
    } catch { check(false, "malformed harness: \(error)") }

    section("Ingress socket: rate limits, caps, concurrency")
    do {
        var lim = NotificationIngressServer.Limits(); lim.perPeerPerMinute = 5
        let clock = FakeClock()
        let h = IngHarness(limits: lim, name: "rl", clock: clock.read)
        try h.server.start()
        var oks = 0, limited = 0
        for i in 0..<8 {
            let r = RawClient.request(path: h.path, good("n\(i)"))
            if r.reply?["ok"] as? Bool == true { oks += 1 } else if r.reply?["error"] as? String == "rate limited" { limited += 1 }
        }
        eq(oks, 5, "per-peer limit: 5 requests admitted")
        eq(limited, 3, "per-peer limit: the next 3 get \"rate limited\"")
        eq(h.received.get().count, 5, "rate-limited requests never reach the handler")
        eq(h.server.currentStats.rateLimited, 3, "rate limiting is counted")
        clock.advance(61)
        check(RawClient.request(path: h.path, good("later")).reply?["ok"] as? Bool == true, "the per-peer window slides")
        h.server.stop()
        var lim2 = NotificationIngressServer.Limits(); lim2.globalPerMinute = 3
        let h2 = IngHarness(limits: lim2, name: "gl")
        try h2.server.start()
        var okc = 0
        for i in 0..<6 where RawClient.request(path: h2.path, good("g\(i)")).reply?["ok"] as? Bool == true { okc += 1 }
        eq(okc, 3, "global limit applies across peers")
        h2.server.stop()
    } catch { check(false, "rate harness: \(error)") }
    do {
        var lim = NotificationIngressServer.Limits(); lim.perPeerPerMinute = 10_000; lim.globalPerMinute = 10_000
        let h = IngHarness(limits: lim, name: "cc")
        try h.server.start()
        let group = DispatchGroup()
        let replies = Atomic<[Bool]>([])
        for i in 0..<64 {
            group.enter()
            DispatchQueue.global().async {
                let r = RawClient.request(path: h.path, good("c\(i)"), timeout: 10)
                replies.mutate { $0.append(r.reply?["ok"] as? Bool == true) }
                group.leave()
            }
        }
        await withCheckedContinuation { cont in group.notify(queue: .global()) { cont.resume() } }
        eq(replies.get().filter { $0 }.count, 64, "64 concurrent clients all get ok:true")
        check(await waitUntil(5) { h.received.get().count == 64 }, "all 64 notifications were delivered (\(h.received.get().count))")
        eq(Set(h.received.get().map { $0.title }).count, 64, "...each exactly once")
        check(await waitUntil { h.server.connectionCount == 0 }, "all connections are released")
        h.server.stop()
    } catch { check(false, "concurrency harness: \(error)") }
    do {
        var lim = NotificationIngressServer.Limits(); lim.maxConnections = 8; lim.readDeadline = 5
        let h = IngHarness(limits: lim, name: "cap")
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

    section("Ingress socket: stop while connected, zero cost when stopped")
    do {
        let h = IngHarness(name: "sc")
        try h.server.start()
        guard let c = RawClient(path: h.path) else { check(false, "connect failed"); return }
        c.send("{\"v\":1,\"title\":\"half")
        check(await waitUntil { h.server.connectionCount == 1 }, "a client is mid-request")
        let t = Date()
        h.server.stop()
        let (_, eof) = c.readAll(timeout: 2)
        check(eof && Date().timeIntervalSince(t) < 1.5, "stop() while a client is connected closes it promptly")
        check(!FileManager.default.fileExists(atPath: h.path), "...and removes the socket file")
        eq(h.server.connectionCount, 0, "...with no connection left")
        c.closeNow()
        let h2 = IngHarness(name: "sr")
        h2.respond = { _ in nil }
        try h2.server.start()
        guard let c2 = RawClient(path: h2.path) else { check(false, "connect failed"); return }
        c2.send(good()); c2.shutdownWrite()
        check(await waitUntil { h2.received.get().count == 1 }, "a request is awaiting its reply")
        h2.server.stop()
        let (d2, eof2) = c2.readAll(timeout: 2)
        check(eof2 && !String(decoding: d2, as: UTF8.self).contains("\"ok\":true"), "stop() while a reply is pending closes without a success reply")
        h2.pendingReplies.get().last?(.ok(id: UUID()))
        check(true, "a handler answering after stop() is harmless")
        c2.closeNow()
    } catch { check(false, "stop harness: \(error)") }
    do {
        let before = socketFDCount()
        let h = IngHarness(name: "z")
        check(!h.server.isRunning && h.server.connectionCount == 0, "a server that was never started owns nothing")
        eq(socketFDCount(), before, "...and holds no socket descriptor")
        try h.server.start()
        check(socketFDCount() > before, "running: one listening descriptor")
        for _ in 0..<5 { _ = RawClient.request(path: h.path, good()) }
        h.server.stop()
        check(await waitUntil { socketFDCount() == before }, "stopped: every descriptor is released again (\(socketFDCount()) vs \(before))")
        check(!FileManager.default.fileExists(atPath: h.path), "stopped: no socket file")
        check(RawClient(path: h.path) == nil, "stopped: nothing listens")
    } catch { check(false, "zero-cost harness: \(error)") }
    check(await waitUntil { socketFDCount() <= baselineFDs }, "after all socket tests no descriptor leaked (\(socketFDCount()) vs baseline \(baselineFDs))")
}
