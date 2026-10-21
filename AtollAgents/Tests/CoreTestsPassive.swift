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

// Round 2: exact session<->file mapping, the passive busy/idle hybrid, "finished since you last looked",
// subagent grouping, metadata and the polling budget. Real Codex/Claude fd behaviour needs a live session: these tests
// SIMULATE it (a helper process that holds a file open = Codex, one that appends-and-closes = Claude Code).

private let T0 = Date(timeIntervalSince1970: Double(Int(Date().timeIntervalSince1970)))   // whole seconds: utimes granularity
private let claudeBin = "/Users/me/.local/share/claude/versions/2.1.299"
private let codexBin = "/opt/homebrew/bin/codex"
private let K = SessionKey(kind: .claudeCode, id: "u1")

private func codexDayDir(_ codexDir: String, daysAgo: Int = 0) -> String {
    let d = T0.addingTimeInterval(-Double(daysAgo) * 86400)
    let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: d)
    return codexDir + String(format: "/sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!)
}

@discardableResult
private func writeRollout(_ codexDir: String, id: String, cwd: String, mtimeAgo: TimeInterval, lines: [[String: Any]] = [], parent: String? = nil,
                          nestedParent: Bool = false, daysAgo: Int = 0) -> String {
    var meta: [String: Any] = ["id": id, "cwd": cwd, "timestamp": iso(T0.addingTimeInterval(-mtimeAgo - 5))]
    if let p = parent { if nestedParent { meta["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": p]]] } else { meta["parent_thread_id"] = p } }
    let path = codexDayDir(codexDir, daysAgo: daysAgo) + "/rollout-2026-10-21T09-00-00-\(id).jsonl"
    write(path, ([Fx.rollout("session_meta", meta, ts: iso(T0.addingTimeInterval(-mtimeAgo - 5)))] + lines).map { jsonString($0) }.joined(separator: "\n") + "\n")
    setMTime(path, T0.addingTimeInterval(-mtimeAgo))
    return path
}

private func claudeTranscript(_ claudeDir: String, cwd: String, id: String, mtimeAgo: TimeInterval, lines: [[String: Any]]) -> String {
    let path = claudeDir + "/projects/\(claudeSlug(cwd))/\(id).jsonl"
    write(path, lines.map { jsonString($0) }.joined(separator: "\n") + "\n")
    setMTime(path, T0.addingTimeInterval(-mtimeAgo))
    return path
}

private func userLine(_ text: String, ago: TimeInterval = 5) -> [String: Any] { ["type": "user", "timestamp": iso(T0.addingTimeInterval(-ago)), "message": ["content": text]] }
private func asstLine(_ text: String, end: Bool = false, ago: TimeInterval = 4, model: String = "claude-opus-4-7") -> [String: Any] {
    var m: [String: Any] = ["model": model, "content": [["type": "text", "text": text]]]
    if end { m["stop_reason"] = "end_turn" }
    return ["type": "assistant", "timestamp": iso(T0.addingTimeInterval(-ago)), "message": m]
}

private func reg(_ base: String, _ procs: FakeProcs, now: Date = T0, policy: PassivePolicy = .default) -> DiscoveryRegistry {
    let r = DiscoveryRegistry(config: DiscoveryConfig(claudeDir: base + "/claude", codexDir: base + "/codex"), source: procs, apps: PlistAppResolver(), now: { now })
    r.policy = policy
    return r
}

private func hookEvent(_ p: AgentEventPayload, key: SessionKey = K, pid: Int32? = nil) -> AgentEvent {
    AgentEvent(kind: key.kind, sessionID: key.id, payload: p, provenance: .hook, cwd: "/work/proj", pid: pid)
}

private func apply(_ st: inout ReducerState, _ p: AgentEventPayload, _ t: TimeInterval, key: SessionKey = K) {
    SessionReducer.apply(hookEvent(p, key: key), to: &st, now: T0.addingTimeInterval(t))
}

private final class FakeActivation: ActivationObserving {
    var handler: ((String) -> Void)?
    var starts = 0, stops = 0
    func start(_ handler: @escaping (String) -> Void) { starts += 1; self.handler = handler }
    func stop() { stops += 1; handler = nil }
}

func runPassiveTests() async {
    section("Open-file listing (libproc PROC_PIDLISTFDS), real processes")
    do {
        let dir = makeTmp("fd")
        let src = LibprocSource()
        let me = getpid()
        let mine = dir + "/held-by-me.txt"
        let h = open(mine, O_RDWR | O_CREAT, 0o600)
        let real = realPath(mine)
        check(src.openVnodePaths(me).contains(real), "a file this process holds open is listed (\(real))")
        close(h)
        check(!src.openVnodePaths(me).contains(real), "...and disappears once closed")
        check(src.openVnodePaths(999_999).isEmpty, "nonexistent pid: empty list")
        let selfPath = src.path(me) ?? CommandLine.arguments[0]
        let held = dir + "/rollout-held.jsonl"
        let holder = Process(); holder.executableURL = URL(fileURLWithPath: selfPath); holder.arguments = ["--aa-hold", held, "20"]
        try holder.run()
        _ = await waitUntil(8) { FileManager.default.fileExists(atPath: held) }
        let heldReal = realPath(held)
        let ok = await waitUntil(8) { src.openVnodePaths(holder.processIdentifier).contains(heldReal) }
        check(ok, "SIMULATED Codex: another process that keeps a file open is seen holding it")
        await reap(holder)
        let appended = dir + "/transcript.jsonl"
        let appender = Process(); appender.executableURL = URL(fileURLWithPath: selfPath); appender.arguments = ["--aa-append", appended, "6"]
        try appender.run()
        check(await waitUntil(8) { FileManager.default.fileExists(atPath: appended) }, "SIMULATED Claude: the appender is writing")
        let appReal = realPath(appended)
        var heldCount = 0
        for _ in 0..<30 { if src.openVnodePaths(appender.processIdentifier).contains(appReal) { heldCount += 1 }; usleep(7_000) }
        check(heldCount < 15, "SIMULATED Claude: an append-and-close writer does not hold its transcript open (\(heldCount)/30 samples)")
        await reap(appender)
        // Hold a file open ourselves: whether stdout is a tty (a vnode) or a pipe depends on how the
        // tests are run (terminal vs CI), so only a file this test opened is guaranteed to be listed.
        let own = dir + "/own-open-file.txt"
        FileManager.default.createFile(atPath: own, contents: Data("x".utf8))
        if let handle = FileHandle(forReadingAtPath: own) {
            check(src.openVnodePaths(me).contains(realPath(own)), "the listing includes a file this process holds open")
            try? handle.close()
        } else { check(false, "could not open a file to list") }
    } catch { check(false, "fd listing section: \(error)") }

    section("Exact Codex mapping through open files (fake fds)")
    do {
        let base = makeTmp("cx")
        let codexDir = base + "/codex"
        let idA = "0198cccc-0000-7000-8000-00000000000a", idB = "0198cccc-0000-7000-8000-00000000000b", idC = "0198cccc-0000-7000-8000-00000000000c"
        let idOld = "0198cccc-0000-7000-8000-0000000000d0"
        let pA = writeRollout(codexDir, id: idA, cwd: "/work/same", mtimeAgo: 40, lines: [Fx.eventMsg("user_message", ["message": "A prompt"], ts: iso(T0.addingTimeInterval(-41))), Fx.eventMsg("task_complete", [:], ts: iso(T0.addingTimeInterval(-40)))])
        let pB = writeRollout(codexDir, id: idB, cwd: "/work/same", mtimeAgo: 10, lines: [Fx.eventMsg("user_message", ["message": "B prompt"], ts: iso(T0.addingTimeInterval(-11)))])
        _ = writeRollout(codexDir, id: idC, cwd: "/work/same", mtimeAgo: 100, lines: [Fx.eventMsg("user_message", ["message": "C prompt"])])
        let pOld = writeRollout(codexDir, id: idOld, cwd: "/work/resumed", mtimeAgo: 5, lines: [Fx.eventMsg("user_message", ["message": "old resumed"], ts: iso(T0.addingTimeInterval(-6)))], daysAgo: 12)
        let procs = FakeProcs()
        // Process 1 started LATER than process 2: start-time pairing would swap them, the open files must not.
        procs.add(7201, tty: 21, start: T0.addingTimeInterval(-100), path: codexBin, cwd: "/work/same", argv: ["codex"])
        procs.add(7202, tty: 22, start: T0.addingTimeInterval(-200), path: codexBin, cwd: "/work/same", argv: ["codex"])
        procs.add(7203, tty: 23, start: T0.addingTimeInterval(-300), path: codexBin, cwd: "/work/resumed", argv: ["codex"])
        procs.add(7204, start: T0.addingTimeInterval(-300), path: codexBin, cwd: "/work/headless", argv: ["codex"])      // no tty
        procs.setFDs(7201, ["/dev/null", "/private/tmp/unrelated.log", realPath(pA)])
        procs.setFDs(7202, [realPath(pB)])
        procs.setFDs(7203, [realPath(pOld), "/etc/hosts"])
        procs.setFDs(7204, [])
        check(pA.hasPrefix(codexDir) && realPath(pA).hasPrefix(realPath(codexDir)), "fixture: rollout paths live under the (resolved) codex dir")
        let res = reg(base, procs).scan()
        let by = Dictionary(uniqueKeysWithValues: res.sessions.filter { $0.key.kind == .codex && !$0.key.id.hasPrefix("pid:") }.map { ($0.key.id, $0) })
        eq(by[idA]?.pid ?? 0, 7201, "exact: pid 7201 holds rollout A")
        eq(by[idB]?.pid ?? 0, 7202, "exact: pid 7202 holds rollout B (start-time pairing would have swapped them)")
        eq(by[idOld]?.pid ?? 0, 7203, "exact: a resumed session's rollout in an OLD date directory is found through the open file")
        eq(by[idOld]?.lastPrompt ?? "", "old resumed", "exact: its content is read")
        check(by[idC] == nil || by[idC]?.pid == nil, "an unheld rollout is not attributed to any process")
        check(!res.sessions.contains(where: { $0.pid == 7204 }), "a codex process without a controlling tty is not an interactive session")
        // several open rollouts: newest by mtime wins
        procs.setFDs(7201, [realPath(pA), realPath(pB)])
        procs.setFDs(7202, [])
        let res2 = reg(base, procs).scan()
        eq(res2.sessions.first(where: { $0.pid == 7201 })?.key.id ?? "", idB, "several open rollouts: the newest by mtime is picked")
        // no fds at all (e.g. permission denied): heuristics still work
        procs.setFDs(7201, []); procs.setFDs(7203, [])
        let res3 = reg(base, procs).scan()
        check(res3.sessions.contains(where: { $0.pid == 7201 }), "no open files readable: the process is still listed (cwd heuristics)")
        // zst held open
        let zst = codexDayDir(codexDir) + "/rollout-2026-10-21T09-00-00-0198cccc-0000-7000-8000-0000000000e0.jsonl.zst"
        writeData(zst, Data([0x28, 0xB5, 0x2F, 0xFD]))
        procs.setFDs(7203, [realPath(zst)])
        let res4 = reg(base, procs).scan()
        check(res4.sessions.contains(where: { $0.pid == 7203 && $0.key.id == "0198cccc-0000-7000-8000-0000000000e0" }), "a compressed rollout held open still maps exactly (no content)")
    } catch { check(false, "codex exact section: \(error)") }

    section("Claude: map by cwd, pair by start time, tty required")
    do {
        let base = makeTmp("cm")
        let claudeDir = base + "/claude"
        let cwd = "/work/twins"
        // Two transcripts created one second apart; the processes started at those moments.
        let t1 = claudeTranscript(claudeDir, cwd: cwd, id: "tw-1", mtimeAgo: 500, lines: [userLine("first twin", ago: 500)])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let t2 = claudeTranscript(claudeDir, cwd: cwd, id: "tw-2", mtimeAgo: 400, lines: [userLine("second twin", ago: 400)])
        setMTime(t1, T0.addingTimeInterval(-20)); setMTime(t2, T0.addingTimeInterval(-300))     // mtime order is the OPPOSITE of birth order
        let b1 = DiscoveryRegistry.birthTime(t1)!, b2 = DiscoveryRegistry.birthTime(t2)!
        check(b2.timeIntervalSince(b1) > 1, "fixture: the transcripts have different birth times")
        let procs = FakeProcs()
        procs.add(6301, tty: 31, start: b1.addingTimeInterval(-2), path: claudeBin, cwd: cwd, argv: ["claude"])
        procs.add(6302, tty: 32, start: b2.addingTimeInterval(-2), path: claudeBin, cwd: cwd, argv: ["claude"])
        procs.add(6303, start: b1, path: claudeBin, cwd: cwd, argv: ["claude"])                    // no tty: headless/background
        let res = reg(base, procs, now: Date()).scan()
        let a = res.sessions.first(where: { $0.pid == 6301 }), b = res.sessions.first(where: { $0.pid == 6302 })
        eq(a?.key.id ?? "", "tw-1", "two sessions in one cwd: paired by transcript birth time vs process start (first)")
        eq(b?.key.id ?? "", "tw-2", "two sessions in one cwd: paired by transcript birth time vs process start (second)")
        check(!res.sessions.contains(where: { $0.pid == 6303 }), "a claude process without a controlling tty is not an interactive session")
        eq(a?.lastPrompt ?? "", "first twin", "...and each reads its own transcript")
        // registry id beats any heuristic
        let procs2 = FakeProcs()
        procs2.add(6401, tty: 33, start: b1, path: claudeBin, cwd: cwd, argv: ["claude"])
        write(claudeDir + "/sessions/6401.json", registryJSON(pid: 6401, sid: "tw-2", cwd: cwd, startedAt: b1, status: "idle"))
        check(reg(base, procs2, now: Date()).scan().sessions.first?.key.id == "tw-2", "the registry's session id wins over cwd/time heuristics")
        // exact: the process does hold the transcript open (not observed for Claude Code, but handled)
        let procs3 = FakeProcs()
        procs3.add(6501, tty: 34, start: b1, path: claudeBin, cwd: cwd, argv: ["claude"])
        procs3.add(6502, tty: 35, start: b1, path: claudeBin, cwd: cwd, argv: ["claude"])
        procs3.setFDs(6502, [realPath(t2)])
        let r3 = reg(base, procs3, now: Date()).scan()
        eq(r3.sessions.first(where: { $0.pid == 6502 })?.key.id ?? "", "tw-2", "an open transcript file is an exact answer when present")
        // a single process takes the newest transcript, a stale one older than the process is ignored
        let procs4 = FakeProcs()
        procs4.add(6601, tty: 36, start: T0.addingTimeInterval(-100), path: claudeBin, cwd: "/work/solo2", argv: ["claude"])
        _ = claudeTranscript(claudeDir, cwd: "/work/solo2", id: "older", mtimeAgo: 5000, lines: [userLine("ancient", ago: 5000)])
        _ = claudeTranscript(claudeDir, cwd: "/work/solo2", id: "newer", mtimeAgo: 30, lines: [userLine("recent", ago: 30)])
        eq(reg(base, procs4, now: T0).scan().sessions.first?.key.id ?? "", "newer", "a lone process maps to the newest transcript in its cwd")
    } catch { check(false, "claude mapping section: \(error)") }

    section("Passive busy/idle hybrid: the 30 s boundary")
    do {
        func status(ago: TimeInterval, lines: [[String: Any]]? = nil, policy: PassivePolicy = .default) -> (SessionStatus?, String?) {
            let base = makeTmp("hy")
            let procs = FakeProcs()
            procs.add(5101, tty: 41, start: T0.addingTimeInterval(-3600), path: claudeBin, cwd: "/work/hy", argv: ["claude"])
            _ = claudeTranscript(base + "/claude", cwd: "/work/hy", id: "hy-1", mtimeAgo: ago, lines: lines ?? [userLine("work on it", ago: ago)])
            let s = reg(base, procs, policy: policy).scan().sessions.first
            return (s?.status, s?.statusDetail)
        }
        eq(status(ago: 0).0 ?? .unknown, .running, "written just now: running")
        eq(status(ago: 5).0 ?? .unknown, .running, "written 5 s ago: running")
        eq(status(ago: 29).0 ?? .unknown, .running, "written 29 s ago: running")
        eq(status(ago: 30).0 ?? .unknown, .idle, "written exactly 30 s ago: idle (boundary)")
        eq(status(ago: 31).0 ?? .unknown, .idle, "written 31 s ago: idle")
        eq(status(ago: 3600).0 ?? .unknown, .idle, "written an hour ago, process alive: idle")
        eq(status(ago: 10, policy: PassivePolicy(busyWindow: 5)).0 ?? .unknown, .idle, "the busy window is configurable (5 s: 10 s ago is idle)")
        eq(status(ago: 10, policy: PassivePolicy(busyWindow: 60)).0 ?? .unknown, .running, "the busy window is configurable (60 s: 10 s ago is running)")
        eq(status(ago: 3).1 ?? "", "estimated from activity", "the session says its status is estimated")
        eq(status(ago: 2, lines: [userLine("q", ago: 4), asstLine("All done", end: true, ago: 2)]).0 ?? .unknown, .idle, "a turn that visibly ended is idle at once (no afterglow)")
        eq(status(ago: 2, lines: [userLine("q", ago: 4), asstLine("starting", ago: 3), ["type": "assistant", "message": ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": "make"]]]]]]).0 ?? .unknown, .running, "a turn that is mid-tool and fresh is running")
        // Codex
        func cstatus(ago: TimeInterval, lines: [[String: Any]]) -> SessionStatus? {
            let base = makeTmp("hc")
            let procs = FakeProcs()
            procs.add(5201, tty: 42, start: T0.addingTimeInterval(-3600), path: codexBin, cwd: "/work/hc", argv: ["codex"])
            let p = writeRollout(base + "/codex", id: "0198dddd-0000-7000-8000-000000000001", cwd: "/work/hc", mtimeAgo: ago, lines: lines)
            procs.setFDs(5201, [realPath(p)])
            return reg(base, procs).scan().sessions.first?.status
        }
        eq(cstatus(ago: 12, lines: [Fx.eventMsg("task_started")]) ?? .unknown, .running, "codex: rollout written 12 s ago: running")
        eq(cstatus(ago: 45, lines: [Fx.eventMsg("task_started")]) ?? .unknown, .idle, "codex: rollout quiet for 45 s: idle")
        eq(cstatus(ago: 2, lines: [Fx.eventMsg("task_started"), Fx.eventMsg("task_complete")]) ?? .unknown, .idle, "codex: task_complete just written: idle at once")
        eq(cstatus(ago: 300, lines: [Fx.eventMsg("task_started"), Fx.eventMsg("exec_approval_request")]) ?? .unknown, .needsPermission, "codex: a pending approval stays needsPermission while quiet")
        // registry status is exact and carries no estimate caveat
        let base = makeTmp("hr")
        let procs = FakeProcs()
        procs.add(5301, tty: 43, start: T0.addingTimeInterval(-3600), path: claudeBin, cwd: "/work/hr", argv: ["claude"])
        write(base + "/claude/sessions/5301.json", registryJSON(pid: 5301, sid: "hr-1", cwd: "/work/hr", startedAt: T0.addingTimeInterval(-3600), status: "idle"))
        _ = claudeTranscript(base + "/claude", cwd: "/work/hr", id: "hr-1", mtimeAgo: 1, lines: [userLine("x", ago: 1)])
        let hr = reg(base, procs, now: Date()).scan().sessions.first
        eq(hr?.status ?? .unknown, .idle, "registry status wins over file activity"); check(hr?.statusDetail == nil, "...and is not labelled as an estimate")
        check(PassivePolicy.default.busyWindow == 30 && PassivePolicy.default.missesToEnd == 2 && PassivePolicy.default.idleDrop == 21600, "default policy: 30 s, 2 misses, 6 h")
    }

    section("Passive lifecycle: 2 misses, 6 h drop, live status overrides")
    do {
        var st = ReducerState()
        var d = DiscoveredSession(key: K, provenance: .processScan, cwd: "/w"); d.pid = 11; d.status = .running; d.statusProvenance = .transcript; d.statusDetail = "estimated from activity"
        SessionReducer.apply(discovered: [d], to: &st, now: T0)
        eq(st.sessions[K]?.statusDetail ?? "", "estimated from activity", "reducer keeps the estimate caveat")
        SessionReducer.apply(discovered: [], to: &st, now: T0.addingTimeInterval(5))
        check(st.sessions[K]?.status == .running, "process gone for 1 scan: unchanged")
        SessionReducer.apply(discovered: [d], to: &st, now: T0.addingTimeInterval(10))
        SessionReducer.apply(discovered: [], to: &st, now: T0.addingTimeInterval(15))
        check(st.sessions[K]?.status == .running, "a reappearance resets the miss counter")
        SessionReducer.apply(discovered: [], to: &st, now: T0.addingTimeInterval(20))
        eq(st.sessions[K]?.status ?? .unknown, .done, "process gone for 2 consecutive scans: done")
        var st2 = ReducerState()
        SessionReducer.apply(discovered: [d], to: &st2, now: T0)
        SessionReducer.apply(discovered: [], policy: PassivePolicy(missesToEnd: 3), to: &st2, now: T0.addingTimeInterval(5))
        SessionReducer.apply(discovered: [], policy: PassivePolicy(missesToEnd: 3), to: &st2, now: T0.addingTimeInterval(10))
        check(st2.sessions[K]?.status == .running, "misses-to-end is configurable (3: still running after 2)")
        SessionReducer.apply(discovered: [], policy: PassivePolicy(missesToEnd: 3), to: &st2, now: T0.addingTimeInterval(15))
        check(st2.sessions[K]?.status == .done, "...and ends after 3")

        var idle = DiscoveredSession(key: K, provenance: .registry, cwd: "/w"); idle.status = .idle; idle.lastActivity = T0
        var st3 = ReducerState()
        SessionReducer.apply(discovered: [idle], to: &st3, now: T0)
        SessionReducer.expire(&st3, now: T0.addingTimeInterval(5 * 3600), isPidAlive: { _, _ in true })
        check(st3.sessions[K] != nil, "idle for 5 h: kept")
        SessionReducer.expire(&st3, now: T0.addingTimeInterval(6 * 3600 + 1), isPidAlive: { _, _ in true })
        check(st3.sessions[K] == nil, "idle for more than 6 h: dropped")
        var st4 = ReducerState()
        SessionReducer.apply(discovered: [idle], to: &st4, now: T0)
        SessionReducer.expire(&st4, now: T0.addingTimeInterval(120), policy: PassivePolicy(idleDrop: 60), isPidAlive: { _, _ in true })
        check(st4.sessions[K] == nil, "the idle-drop threshold is configurable")
        var run = DiscoveredSession(key: K, provenance: .registry, cwd: "/w"); run.status = .running; run.lastActivity = T0
        var st5 = ReducerState()
        SessionReducer.apply(discovered: [run], to: &st5, now: T0)
        SessionReducer.expire(&st5, now: T0.addingTimeInterval(7 * 3600), isPidAlive: { _, _ in true })
        check(st5.sessions[K] != nil, "a running session is never dropped by the idle rule")
        var st6 = ReducerState()
        apply(&st6, .promptSubmit(prompt: "p", title: nil), 0)
        apply(&st6, .stop(lastMessage: nil), 1)
        SessionReducer.expire(&st6, now: T0.addingTimeInterval(8 * 3600), isPidAlive: { _, _ in true })
        check(st6.sessions[K] != nil, "a live (hook) session is not dropped by the passive idle rule")
        // discovery-level drop
        let base = makeTmp("dd")
        let procs = FakeProcs()
        procs.add(5401, tty: 51, start: T0.addingTimeInterval(-86400), path: claudeBin, cwd: "/work/old1", argv: ["claude"])
        procs.add(5402, tty: 52, start: T0.addingTimeInterval(-86400), path: claudeBin, cwd: "/work/old2", argv: ["claude"])
        _ = claudeTranscript(base + "/claude", cwd: "/work/old1", id: "o1", mtimeAgo: 7 * 3600, lines: [userLine("old", ago: 7 * 3600)])
        _ = claudeTranscript(base + "/claude", cwd: "/work/old2", id: "o2", mtimeAgo: 5 * 3600, lines: [userLine("recentish", ago: 5 * 3600)])
        let ids = reg(base, procs).scan().sessions.map { $0.key.id }
        check(!ids.contains("o1") && ids.contains("o2"), "a session idle for 7 h is not listed, one idle for 5 h is")
        // live status overrides the passive estimate
        var st7 = ReducerState()
        apply(&st7, .promptSubmit(prompt: "p", title: nil), 0)
        var est = DiscoveredSession(key: K, provenance: .processScan, cwd: "/work/proj"); est.pid = 5; est.status = .idle; est.statusProvenance = .transcript; est.statusDetail = "estimated from activity"
        SessionReducer.apply(discovered: [est], to: &st7, now: T0.addingTimeInterval(10))
        eq(st7.sessions[K]?.status ?? .unknown, .running, "a fresh hook status overrides the passive estimate")
        check(st7.sessions[K]?.statusDetail == nil, "...and the session is not labelled as estimated")
        // pid reuse: same pid, different start time => not our session any more
        var st8 = ReducerState()
        var pd = DiscoveredSession(key: K, provenance: .registry, cwd: "/w"); pd.pid = 77; pd.processStart = T0; pd.status = .running
        SessionReducer.apply(discovered: [pd], to: &st8, now: T0)
        SessionReducer.expire(&st8, now: T0.addingTimeInterval(60), isPidAlive: { _, start in start == T0 ? false : true })
        eq(st8.sessions[K]?.status ?? .unknown, .done, "pid reuse (start time no longer matches): the session is done")
    }

    section("Finished since you last looked (hasUnseenCompletion)")
    do {
        var st = ReducerState()
        apply(&st, .sessionStart(source: "startup", title: nil), 0)
        check(st.sessions[K]?.hasUnseenCompletion == false, "a new session has nothing unseen")
        apply(&st, .promptSubmit(prompt: "go", title: nil), 1)
        apply(&st, .stop(lastMessage: "done"), 2)
        check(st.sessions[K]?.hasUnseenCompletion == true, "Stop after a running turn sets the flag")
        apply(&st, .promptSubmit(prompt: "again", title: nil), 3)
        check(st.sessions[K]?.hasUnseenCompletion == false, "a new prompt clears it")
        apply(&st, .stop(lastMessage: nil), 4)
        apply(&st, .stop(lastMessage: nil), 5)
        check(st.sessions[K]?.hasUnseenCompletion == true, "(still set after another Stop)")
        SessionReducer.acknowledge(&st, key: K)
        check(st.sessions[K]?.hasUnseenCompletion == false, "acknowledge(key) clears it")
        var idleOnly = ReducerState()
        apply(&idleOnly, .sessionStart(source: "startup", title: nil), 0)
        apply(&idleOnly, .stop(lastMessage: nil), 1)
        check(idleOnly.sessions[K]?.hasUnseenCompletion == false, "an idle session that 'stops' did not finish anything")
        var intr = ReducerState()
        apply(&intr, .promptSubmit(prompt: "p", title: nil), 0)
        apply(&intr, .interrupt, 1)
        check(intr.sessions[K]?.hasUnseenCompletion == false, "a user interrupt is not a completion")
        var ended = ReducerState()
        apply(&ended, .promptSubmit(prompt: "p", title: nil), 0)
        apply(&ended, .sessionEnd(reason: nil), 1)
        check(ended.sessions[K]?.hasUnseenCompletion == true, "a session that ends while running counts as finished")
        var perm = ReducerState()
        apply(&perm, .promptSubmit(prompt: "p", title: nil), 0)
        apply(&perm, .permissionRequest(PermissionInfo(tool: ToolInfo(name: "Bash", summary: "x"), mcpServer: nil, suggestions: [], suggestionEntries: [])), 1)
        apply(&perm, .approvalResolved(allowed: true), 2)
        check(perm.sessions[K]?.hasUnseenCompletion == false, "waiting for permission and resuming is not a completion")
        // passive transitions
        var pas = ReducerState()
        var r = DiscoveredSession(key: K, provenance: .processScan, cwd: "/w"); r.pid = 9; r.status = .running; r.statusProvenance = .transcript
        SessionReducer.apply(discovered: [r], to: &pas, now: T0)
        check(pas.sessions[K]?.hasUnseenCompletion == false, "a passive session first seen running has nothing unseen")
        var q = r; q.status = .idle
        SessionReducer.apply(discovered: [q], to: &pas, now: T0.addingTimeInterval(10))
        check(pas.sessions[K]?.hasUnseenCompletion == true, "passive running -> idle sets the flag")
        SessionReducer.apply(discovered: [r], to: &pas, now: T0.addingTimeInterval(20))
        check(pas.sessions[K]?.hasUnseenCompletion == false, "passive idle -> running clears it (a new turn)")
        var gone = ReducerState()
        SessionReducer.apply(discovered: [r], to: &gone, now: T0)
        SessionReducer.apply(discovered: [], to: &gone, now: T0.addingTimeInterval(5))
        SessionReducer.apply(discovered: [], to: &gone, now: T0.addingTimeInterval(10))
        check(gone.sessions[K]?.status == .done && gone.sessions[K]?.hasUnseenCompletion == true, "a running passive session whose process exits is done AND unseen")
        var goneIdle = ReducerState()
        var qi = r; qi.status = .idle
        SessionReducer.apply(discovered: [qi], to: &goneIdle, now: T0)
        SessionReducer.apply(discovered: [], to: &goneIdle, now: T0.addingTimeInterval(5))
        SessionReducer.apply(discovered: [], to: &goneIdle, now: T0.addingTimeInterval(10))
        check(goneIdle.sessions[K]?.hasUnseenCompletion == false, "an idle passive session whose process exits has nothing new to see")
        // 24 h cap
        var cap = ReducerState()
        apply(&cap, .promptSubmit(prompt: "p", title: nil), 0)
        apply(&cap, .stop(lastMessage: nil), 1)
        SessionReducer.expire(&cap, now: T0.addingTimeInterval(23 * 3600), isPidAlive: { _, _ in true })
        check(cap.sessions[K]?.hasUnseenCompletion == true, "still flagged after 23 h")
        SessionReducer.expire(&cap, now: T0.addingTimeInterval(25 * 3600), isPidAlive: { _, _ in true })
        check(cap.sessions[K]?.hasUnseenCompletion == false, "never kept for more than 24 h")
        // acknowledge variants
        var multi = ReducerState()
        let k2 = SessionKey(kind: .codex, id: "x2"), k3 = SessionKey(kind: .claudeCode, id: "x3")
        for k in [K, k2, k3] { apply(&multi, .promptSubmit(prompt: "p", title: nil), 0, key: k); apply(&multi, .stop(lastMessage: nil), 1, key: k) }
        multi.sessions[K]!.hostAppBundleID = "com.apple.Terminal"; multi.sessions[k2]!.hostAppBundleID = "com.mitchellh.ghostty"; multi.sessions[k3]!.hostAppBundleID = "com.apple.Terminal"
        SessionReducer.acknowledge(&multi, hostBundleID: "com.apple.Terminal")
        check(!multi.sessions[K]!.hasUnseenCompletion && !multi.sessions[k3]!.hasUnseenCompletion && multi.sessions[k2]!.hasUnseenCompletion, "activating a host app clears only the sessions hosted there")
        SessionReducer.acknowledge(&multi, key: nil)
        check(multi.sessions.values.allSatisfy { !$0.hasUnseenCompletion }, "acknowledge(nil) clears everything")
    }

    section("Subagent grouping, title and model metadata")
    do {
        // Codex: parent_thread_id from session_meta
        let base = makeTmp("sg")
        let codexDir = base + "/codex"
        let parentID = "0198eeee-0000-7000-8000-00000000000a", childID = "0198eeee-0000-7000-8000-00000000000b", child2 = "0198eeee-0000-7000-8000-00000000000c"
        let pp = writeRollout(codexDir, id: parentID, cwd: "/work/par", mtimeAgo: 4, lines: [Fx.eventMsg("user_message", ["message": "orchestrate"], ts: iso(T0.addingTimeInterval(-6))), Fx.eventMsg("task_started", [:], ts: iso(T0.addingTimeInterval(-5)))])
        writeRollout(codexDir, id: childID, cwd: "/work/par", mtimeAgo: 3, lines: [Fx.eventMsg("task_started", [:], ts: iso(T0.addingTimeInterval(-4)))], parent: parentID)
        writeRollout(codexDir, id: child2, cwd: "/work/par", mtimeAgo: 2, lines: [Fx.eventMsg("task_started", [:], ts: iso(T0.addingTimeInterval(-3)))], parent: parentID, nestedParent: true)
        let procs = FakeProcs()
        procs.add(4001, tty: 61, start: T0.addingTimeInterval(-600), path: codexBin, cwd: "/work/par", argv: ["codex"])
        procs.setFDs(4001, [realPath(pp)])
        let res = reg(base, procs).scan()
        eq(res.sessions.first(where: { $0.key.id == childID })?.parentID ?? "", parentID, "discovery: child rollout carries parent_thread_id")
        eq(res.sessions.first(where: { $0.key.id == child2 })?.parentID ?? "", parentID, "discovery: nested source.subagent...parent_thread_id is found too")
        check(res.sessions.first(where: { $0.key.id == parentID })?.parentID == nil, "discovery: the parent has no parent")
        var st = ReducerState()
        SessionReducer.apply(discovered: res.sessions, to: &st, now: T0)
        let shown = SessionReducer.sorted(st)
        eq(shown.map { $0.key.id }, [parentID], "children are grouped under the parent: only the parent is listed")
        eq(Set(shown[0].subagents.map { $0.id }), Set([childID, child2]), "...and appear in parent.subagents")
        check(shown[0].subagents.allSatisfy { $0.status == .running }, "...with their status (recently written: running)")
        var orphan = ReducerState()
        SessionReducer.apply(discovered: res.sessions.filter { $0.key.id != parentID }, to: &orphan, now: T0)
        eq(SessionReducer.sorted(orphan).count, 2, "children whose parent is unknown stay visible on their own")
        eq(tailMeta(pp, "x"), nil as String?, "a parent rollout has no parent_thread_id")

        // Claude: <session>/subagents/agent-*.jsonl
        let cbase = makeTmp("sc")
        let cprocs = FakeProcs()
        cprocs.add(4101, tty: 62, start: T0.addingTimeInterval(-900), path: claudeBin, cwd: "/work/cl", argv: ["claude"])
        write(cbase + "/claude/sessions/4101.json", registryJSON(pid: 4101, sid: "cl-main", cwd: "/work/cl", startedAt: T0.addingTimeInterval(-900), status: "busy"))
        let main = claudeTranscript(cbase + "/claude", cwd: "/work/cl", id: "cl-main", mtimeAgo: 2, lines: [userLine("use subagents", ago: 20), asstLine("spawning", ago: 2)])
        let subDir = (main as NSString).deletingPathExtension + "/subagents"
        let sidechain: (String) -> String = { text in jsonString(["type": "assistant", "isSidechain": true, "message": ["content": [["type": "text", "text": text]]]]) + "\n" }
        write(subDir + "/agent-a1.jsonl", sidechain("explorer found the bug")); setMTime(subDir + "/agent-a1.jsonl", T0.addingTimeInterval(-5))
        write(subDir + "/agent-a2.jsonl", sidechain("finished long ago")); setMTime(subDir + "/agent-a2.jsonl", T0.addingTimeInterval(-600))
        write(subDir + "/agent-..evil.jsonl", sidechain("x")); write(subDir + "/notes.txt", "x"); write(subDir + "/agent-a3.txt", "x")
        let cres = reg(cbase, cprocs).scan()
        let cs = cres.sessions.first(where: { $0.key.id == "cl-main" })
        eq(Set((cs?.subagents ?? []).map { $0.id }), Set(["a1", "a2"]), "claude: subagents come from <session>/subagents/agent-*.jsonl (unsafe ids and other files ignored)")
        eq(cs?.subagents?.first(where: { $0.id == "a1" })?.status ?? .done, .running, "claude: a subagent file written 5 s ago is running")
        eq(cs?.subagents?.first(where: { $0.id == "a2" })?.status ?? .running, .done, "claude: one quiet for 10 minutes is done")
        eq(cs?.subagents?.first(where: { $0.id == "a1" })?.lastText ?? "", "explorer found the bug", "claude: the subagent's last text is read from its sidechain transcript")
        var cst = ReducerState()
        SessionReducer.apply(discovered: cres.sessions, to: &cst, now: T0)
        eq(Set(cst.sessions[SessionKey(kind: .claudeCode, id: "cl-main")]!.subagents.map { $0.id }), Set(["a1", "a2"]), "claude: subagents reach the session")
        // a hook-owned session keeps its own subagent bookkeeping
        var hooked = ReducerState()
        apply(&hooked, .subagentStart(id: "a1", type: "Explore"), 0, key: SessionKey(kind: .claudeCode, id: "cl-main"))
        apply(&hooked, .subagentStop(id: "a1", type: nil, lastMessage: "by hook", failed: false), 1, key: SessionKey(kind: .claudeCode, id: "cl-main"))
        SessionReducer.apply(discovered: cres.sessions, to: &hooked, now: T0.addingTimeInterval(2))
        let hs = hooked.sessions[SessionKey(kind: .claudeCode, id: "cl-main")]!
        eq(hs.subagents.first(where: { $0.id == "a1" })?.status ?? .running, .done, "hook-tracked subagents are not overwritten by file activity")
        for i in 0..<12 { let f = subDir + "/agent-m\(i).jsonl"; write(f, sidechain("m\(i)")); setMTime(f, T0.addingTimeInterval(-Double(i) - 1)) }
        let many = reg(cbase, cprocs).scan().sessions.first(where: { $0.key.id == "cl-main" })
        check((many?.subagents?.count ?? 99) <= 8, "claude: at most the 8 newest subagent files are read")

        // title = the USER's latest prompt; model from the tail
        let tbase = makeTmp("tm")
        let tprocs = FakeProcs()
        tprocs.add(4201, tty: 63, start: T0.addingTimeInterval(-900), path: claudeBin, cwd: "/work/ti", argv: ["claude"])
        write(tbase + "/claude/sessions/4201.json", registryJSON(pid: 4201, sid: "ti-1", cwd: "/work/ti", startedAt: T0.addingTimeInterval(-900), status: "idle", extra: ["name": ""]))
        _ = claudeTranscript(tbase + "/claude", cwd: "/work/ti", id: "ti-1", mtimeAgo: 100, lines: [
            ["type": "ai-title", "aiTitle": "Auto generated title"],
            userLine("first question", ago: 300), asstLine("A long agent answer that should not become the title", end: true, ago: 290, model: "claude-sonnet-4-6"),
            userLine("second question, the latest", ago: 120), asstLine("another chatty reply", end: true, ago: 100, model: "claude-opus-4-7")])
        let ti = reg(tbase, tprocs).scan().sessions.first
        eq(ti?.title ?? "", "second question, the latest", "title is the user's LATEST prompt, not the agent's reply or the auto title")
        eq(ti?.model ?? "", "claude-opus-4-7", "model comes from the transcript tail (latest assistant entry)")
        var tst = ReducerState()
        SessionReducer.apply(discovered: [ti!], to: &tst, now: T0)
        let ts = tst.sessions[SessionKey(kind: .claudeCode, id: "ti-1")]
        eq(ts?.title ?? "", "second question, the latest", "reducer: title of a passive session"); eq(ts?.model ?? "", "claude-opus-4-7", "reducer: AgentSession.model populated for a passive session")
        let cxbase = makeTmp("tx")
        let cxp = writeRollout(cxbase + "/codex", id: "0198ffff-0000-7000-8000-000000000001", cwd: "/work/tx", mtimeAgo: 50, lines: [
            Fx.rollout("turn_context", ["cwd": "/work/tx", "model": "gpt-5-codex"]), Fx.eventMsg("user_message", ["message": "first"]), Fx.eventMsg("agent_message", ["message": "chatter chatter"]), Fx.eventMsg("user_message", ["message": "latest codex prompt"]), Fx.eventMsg("agent_message", ["message": "more chatter"])])
        let cxprocs = FakeProcs()
        cxprocs.add(4301, tty: 64, start: T0.addingTimeInterval(-900), path: codexBin, cwd: "/work/tx", argv: ["codex"])
        cxprocs.setFDs(4301, [realPath(cxp)])
        let cx = reg(cxbase, cxprocs).scan().sessions.first
        eq(cx?.title ?? "", "latest codex prompt", "codex: title is the user's latest prompt"); eq(cx?.model ?? "", "gpt-5-codex", "codex: model from the rollout")
        var hk = ReducerState()
        apply(&hk, .promptSubmit(prompt: "first hook prompt", title: nil), 0)
        apply(&hk, .assistantText("chatter"), 1)
        apply(&hk, .promptSubmit(prompt: "second hook prompt", title: nil), 2)
        eq(hk.sessions[K]?.title ?? "", "second hook prompt", "hook session: title follows the user's latest prompt")
        apply(&hk, .sessionStart(source: "resume", title: "Explicit session title"), 3)
        apply(&hk, .promptSubmit(prompt: "third", title: nil), 4)
        eq(hk.sessions[K]?.title ?? "", "Explicit session title", "an explicit session_title is never replaced by prompts")
    }

    section("Polling budget (DiscoveryLoop active/inactive)")
    eq(DiscoveryLoop.delay(interval: 15, maxBackoff: 60, emptyScans: 0, active: true), 5, "active: one pass per 5 s")
    eq(DiscoveryLoop.delay(interval: 15, maxBackoff: 60, emptyScans: 9, active: true), 5, "active: still 5 s when nothing is found")
    eq(DiscoveryLoop.delay(interval: 15, maxBackoff: 60, emptyScans: 0, active: false), 15, "inactive: 15 s")
    eq(DiscoveryLoop.delay(interval: 15, maxBackoff: 60, emptyScans: 3, active: false), 60, "inactive and empty: 60 s")
    do {
        let n = Atomic(0)
        let loop = DiscoveryLoop(interval: 30, maxBackoff: 60, activeInterval: 0.1, qos: .utility, scan: {
            n.mutate { $0 += 1 }
            var d = DiscoveredSession(key: K, provenance: .registry, cwd: "/"); d.pid = 1
            return DiscoveryResult(sessions: [d], complete: true, notes: [])
        }, deliver: { _ in })
        loop.start()
        await sleepMs(500)
        eq(n.get(), 1, "inactive: a single scan in 0.5 s (cadence 30 s)")
        loop.setActive(true)
        await sleepMs(1000)
        let active = n.get() - 1
        check(active >= 5 && active <= 12, "active (0.1 s): about 10 scans per second, never faster (\(active) in 1 s)")
        loop.setActive(false)
        let before = n.get()
        await sleepMs(600)
        check(n.get() - before <= 1, "back to inactive: scanning relaxes at once (\(n.get() - before) extra scans in 0.6 s)")
        loop.stop(); loop.setActive(true)
        let after = n.get()
        await sleepMs(300)
        eq(n.get(), after, "a stopped loop never scans, even if the UI asks for fast polling")
    }
}

private func tailMeta(_ path: String, _ x: String) -> String? { TranscriptTail().rolloutMeta(path: path)?.parentThreadID }

@MainActor
func runPassiveCenterTests() async {
    section("AgentCenter: unseen completions, acknowledge, polling")
    do {
        let base = makeTmp("pc")
        let sock = base + "/run/agent.sock"
        let obs = FakeActivation()
        var cfg = AgentCenterConfig(socketPath: sock, claudeDir: base + "/claude", codexDir: base + "/codex", boardURL: URL(fileURLWithPath: base + "/b.json"))
        cfg.enableDiscovery = false
        cfg.activationObserver = obs
        let c = AgentCenter(config: cfg)
        eq(obs.starts, 0, "the activation observer is not started before start()")
        c.start()
        eq(obs.starts, 1, "start() begins observing app activation")
        func cj(_ e: String, _ x: [String: Any] = [:]) -> String { jsonString(Fx.claude(e, x)) }
        func finishTurn(_ sid: String) async {
            _ = await sh(hookCommand(socket: sock, blocking: false), stdin: cj("UserPromptSubmit", ["session_id": sid, "prompt": "go"]))
            _ = await sh(hookCommand(socket: sock, blocking: false), stdin: cj("Stop", ["session_id": sid, "last_assistant_message": "done"]))
        }
        await finishTurn("s-a")
        check(await waitUntil { c.unseenCompletionCount == 1 }, "a finished turn raises unseenCompletionCount")
        check(c.sessions.first(where: { $0.key.id == "s-a" })?.hasUnseenCompletion == true, "...and flags that session")
        // host app: tag the session with a host app via the engine's state (hook sessions have none by themselves)
        guard let eng = c.engineForTesting else { check(false, "engine missing"); return }
        _ = eng
        obs.handler?("com.apple.Terminal")
        await sleepMs(100)
        eq(c.unseenCompletionCount, 1, "activating an unrelated app does not clear it")
        c.acknowledge(SessionKey(kind: .claudeCode, id: "s-a"))
        eq(c.unseenCompletionCount, 0, "acknowledge(key) clears it at once")
        await sleepMs(300)
        eq(c.unseenCompletionCount, 0, "...and stays cleared after the engine's next snapshot")
        await finishTurn("s-b"); await finishTurn("s-c")
        check(await waitUntil { c.unseenCompletionCount == 2 }, "two sessions finished: count is 2")
        c.acknowledgeAll()
        eq(c.unseenCompletionCount, 0, "acknowledgeAll() clears everything")
        await sleepMs(300)
        eq(c.sessions.filter { $0.hasUnseenCompletion }.count, 0, "...in the published sessions too")
        // jump clears
        await finishTurn("s-j")
        check(await waitUntil { c.unseenCompletionCount == 1 }, "another completion")
        c.jump(to: SessionKey(kind: .claudeCode, id: "s-j"))
        eq(c.unseenCompletionCount, 0, "pressing jump clears it (even when the jump itself cannot go anywhere)")
        // new prompt clears
        await finishTurn("s-p")
        check(await waitUntil { c.unseenCompletionCount == 1 }, "yet another completion")
        _ = await sh(hookCommand(socket: sock, blocking: false), stdin: cj("UserPromptSubmit", ["session_id": "s-p", "prompt": "next"]))
        check(await waitUntil { c.unseenCompletionCount == 0 }, "a new prompt clears it")
        c.stop()
        eq(obs.stops, 1, "stop() ends the activation observation"); eq(c.unseenCompletionCount, 0, "stop() resets the count")
        c.start(); c.stop()
        eq(obs.starts, 2, "restart observes again")
    }

    section("AgentCenter: host app activation clears completions")
    do {
        let base = makeTmp("ph")
        let procs = FakeProcs()
        let apps = makeTmp("apps")
        let termExe = makeFakeApp(apps, "Terminal", bundleID: "com.apple.Terminal")
        procs.add(10, path: termExe)
        procs.add(3001, ppid: 10, tty: 71, start: T0.addingTimeInterval(-300), path: claudeBin, cwd: "/w/h", argv: ["claude"])
        let dir = base + "/claude"
        func registry(_ status: String) { write(dir + "/sessions/3001.json", registryJSON(pid: 3001, sid: "host-1", cwd: "/w/h", startedAt: T0.addingTimeInterval(-300), status: status)) }
        registry("busy")
        let obs = FakeActivation()
        var cfg = AgentCenterConfig(socketPath: base + "/run/agent.sock", claudeDir: dir, codexDir: base + "/codex", boardURL: URL(fileURLWithPath: base + "/b.json"))
        cfg.processSource = procs; cfg.activationObserver = obs; cfg.discoveryInterval = 0.1; cfg.discoveryActiveInterval = 0.1; cfg.enableServer = false
        let c = AgentCenter(config: cfg)
        c.start()
        c.setNeedsFastPolling(true)
        check(await waitUntil { c.sessions.first?.status == .running }, "registry says busy: running")
        registry("idle")
        check(await waitUntil(4) { c.unseenCompletionCount == 1 }, "busy -> idle is a completion (passive)")
        eq(c.sessions.first?.hostAppBundleID ?? "", "com.apple.Terminal", "the session knows its host app")
        obs.handler?("com.googlecode.iterm2")
        await sleepMs(100)
        eq(c.unseenCompletionCount, 1, "another app coming to the front does not clear it")
        obs.handler?("com.apple.Terminal")
        eq(c.unseenCompletionCount, 0, "activating the session's host app clears it")
        await sleepMs(500)
        eq(c.unseenCompletionCount, 0, "...and it does not come back with the next scan")
        c.stop()
    }

    section("AgentCenter: polling budget")
    do {
        let base = makeTmp("pb")
        let procs = FakeProcs()
        procs.add(1, path: "/sbin/launchd")
        var cfg = AgentCenterConfig(socketPath: base + "/run/agent.sock", claudeDir: base + "/claude", codexDir: base + "/codex", boardURL: URL(fileURLWithPath: base + "/b.json"))
        cfg.processSource = procs; cfg.activationObserver = FakeActivation(); cfg.enableServer = false
        cfg.discoveryInterval = 30; cfg.discoveryActiveInterval = 0.15
        let c = AgentCenter(config: cfg)
        c.setNeedsFastPolling(true)
        eq(procs.listCalls, 0, "nothing scans before start(), even if fast polling was requested")
        c.start()
        await sleepMs(700)
        let fast = procs.listCalls
        check(fast >= 3 && fast <= 7, "fast polling on: a pass every ~0.15 s, never faster (\(fast) passes in 0.7 s)")
        c.setNeedsFastPolling(false)
        await sleepMs(200)
        let relaxed0 = procs.listCalls
        await sleepMs(600)
        check(procs.listCalls - relaxed0 <= 1, "fast polling off: relaxes to the slow cadence (\(procs.listCalls - relaxed0) passes in 0.6 s)")
        c.stop()
        let stopped = procs.listCalls
        c.setNeedsFastPolling(true)
        await sleepMs(500)
        eq(procs.listCalls, stopped, "stopped: zero passes, even when the UI asks for fast polling")
    }
}
