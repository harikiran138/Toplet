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
import Combine
import Darwin

private func cj(_ event: String, _ extra: [String: Any] = [:]) -> String { jsonString(Fx.claude(event, extra)) }

private let permEvent = cj("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"],
    "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]], "behavior": "allow", "destination": "localSettings"]]])

private func decisionBehavior(_ stdout: String) -> String? {
    ((jsonObject(stdout.trimmingCharacters(in: .whitespacesAndNewlines))?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String
}

private func toolEndEvent(_ name: String, _ summary: String) -> AgentEvent {
    AgentEvent(kind: .claudeCode, sessionID: Fx.sid, payload: .toolEnd(ToolInfo(name: name, summary: summary), failed: false), provenance: .hook)
}

private func engineConfig(socket: String, claudeDir: String? = nil, procs: ProcessSource? = nil, discovery: Bool = false) -> AgentEngine.Config {
    var c = AgentEngine.Config()
    c.socketPath = socket
    c.approvalTimeout = 10
    c.enableDiscovery = discovery
    if let cd = claudeDir { c.discovery = DiscoveryConfig(claudeDir: cd, codexDir: cd + "-codex") }
    c.processSource = procs
    c.discoveryInterval = 0.05
    c.discoveryMaxBackoff = 0.15
    c.discoveryActiveInterval = 0.05
    return c
}

func runEngineTests() async {
    section("AgentEngine: hooks -> reducer -> snapshots")
    do {
        let dir = makeTmp("en")
        let sock = dir + "/run/agent.sock"
        let eng = AgentEngine(config: engineConfig(socket: sock))
        let snaps = Atomic<[([AgentSession], [PendingApproval])]>([])
        eng.onSnapshot = { s, p in snaps.mutate { $0.append((s, p)) } }
        let errs = Atomic<[String?]>([])
        eng.onServerError = { e in errs.mutate { $0.append(e) } }
        eng.start()
        eng.start()
        check(eng.isRunning, "engine runs after start() (idempotent)")
        eq(errs.get().count, 1, "start() twice starts the server once")
        check(FileManager.default.fileExists(atPath: sock), "engine owns the socket")
        _ = await sh(hookCommand(socket: sock, blocking: false), stdin: cj("SessionStart", ["source": "startup"]))
        _ = await sh(hookCommand(socket: sock, blocking: false), stdin: cj("UserPromptSubmit", ["prompt": "fix it"]))
        check(await waitUntil { eng.currentSessions.first?.status == .running }, "hook events drive the reducer (running)")
        check(await waitUntil { snaps.get().last?.0.first?.status == .running }, "...and a snapshot is published")
        eq(eng.currentSessions.first?.lastPrompt ?? "", "fix it", "prompt visible in the session")
        check(eng.currentSessions.first?.isLive == true, "hook session is live")
        check(eng.currentSessions.first?.pid == getpid(), "hook ppid becomes the session pid")

        // permission round trip through the engine
        let t = Task { await sh(hookCommand(socket: sock, blocking: true), stdin: permEvent) }
        check(await waitUntil { eng.currentPending.count == 1 }, "pending approval appears in the engine")
        eq(eng.currentSessions.first?.status ?? .unknown, .needsPermission, "session needs permission")
        check(await waitUntil { snaps.get().last?.1.count == 1 }, "the snapshot carries the pending approval")
        eng.decide(eng.currentPending[0].id, .allowOnce)
        let r = await t.value
        eq(decisionBehavior(r.stdout) ?? "", "allow", "decision reaches the hook")
        check(await waitUntil { eng.currentPending.isEmpty && eng.currentSessions.first?.status == .running }, "allowed: pending cleared, session running")

        // letTerminalDecide keeps the session in needsPermission (the terminal still asks)
        let t2 = Task { await sh(hookCommand(socket: sock, blocking: true), stdin: permEvent) }
        check(await waitUntil { eng.currentPending.count == 1 }, "second approval pending")
        eng.decide(eng.currentPending[0].id, .letTerminalDecide)
        _ = await t2.value
        check(await waitUntil { eng.currentPending.isEmpty }, "terminal-decides: pending cleared")
        eq(eng.currentSessions.first?.status ?? .unknown, .needsPermission, "...the session still shows needsPermission until the agent reports again")
        _ = await sh(hookCommand(socket: sock, blocking: false), stdin: cj("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "npm test"], "tool_use_id": "x"]))
        check(await waitUntil { eng.currentSessions.first?.status == .running }, "the next PostToolUse returns the session to running")

        // the session moved on: stale approvals are closed with no reply
        let t3 = Task { await sh(hookCommand(socket: sock, blocking: true), stdin: permEvent) }
        check(await waitUntil { eng.currentPending.count == 1 }, "third approval pending")
        _ = await sh(hookCommand(socket: sock, blocking: false), stdin: cj("Stop", ["last_assistant_message": "done"]))
        let r3 = await t3.value
        eq(r3.stdout, "", "a Stop for the session cancels its pending approval with no reply")
        check(await waitUntil { eng.currentPending.isEmpty }, "...and removes it from the list")
        eq(eng.currentSessions.first?.status ?? .unknown, .idle, "...the session is idle")

        let t4 = Task { await sh(hookCommand(socket: sock, blocking: true), stdin: permEvent) }
        check(await waitUntil { eng.currentPending.count == 1 }, "fourth approval pending")
        eng.ingest(toolEndEvent("Edit", "/some/file"))
        await sleepMs(150)
        eq(eng.currentPending.count, 1, "a tool finishing for a DIFFERENT tool does not cancel the approval (parallel tools)")
        eng.ingest(toolEndEvent("Bash", "npm test"))
        let r4 = await t4.value
        eq(r4.stdout, "", "the same tool finishing means it was answered elsewhere: closed with no reply")
        check(await waitUntil { eng.currentPending.isEmpty }, "...pending cleared")

        // new prompt cancels too
        let t5 = Task { await sh(hookCommand(socket: sock, blocking: true), stdin: permEvent) }
        check(await waitUntil { eng.currentPending.count == 1 }, "fifth approval pending")
        _ = await sh(hookCommand(socket: sock, blocking: false), stdin: cj("UserPromptSubmit", ["prompt": "next"]))
        eq((await t5.value).stdout, "", "a new prompt cancels the pending approval")

        // stop while pending
        let t6 = Task { await sh(hookCommand(socket: sock, blocking: true), stdin: permEvent) }
        check(await waitUntil { eng.currentPending.count == 1 }, "sixth approval pending")
        let publishedBefore = eng.publishCount
        eng.stop()
        eq((await t6.value).stdout, "", "engine stop while pending: empty output, the agent asks in its own UI")
        check(!eng.isRunning, "engine stopped")
        check(!FileManager.default.fileExists(atPath: sock), "...socket removed")
        eng.stop()
        check(true, "stop() is idempotent")
        let afterStop = eng.publishCount
        eng.ingest(AgentEvent(kind: .claudeCode, sessionID: "z", payload: .meta))
        await sleepMs(250)
        eq(eng.publishCount, afterStop, "a stopped engine ignores events and publishes nothing")
        _ = publishedBefore
        check(eng.currentSessions.isEmpty, "a stopped engine holds no sessions")
    }

    eq(AgentEngine.clampedApprovalTimeout(100_000), 600, "approval timeout is clamped to 600 s (below the hook's 900 s backstop)")
    eq(AgentEngine.clampedApprovalTimeout(90), 90, "default approval timeout 90 s is untouched")
    eq(AgentEngine.clampedApprovalTimeout(-5), 0.2, "approval timeout has a floor")

    section("AgentEngine: throttling (<= 10 Hz)")
    do {
        let dir = makeTmp("th")
        let eng = AgentEngine(config: engineConfig(socket: dir + "/run/agent.sock"))
        let snaps = Atomic(0)
        eng.onSnapshot = { _, _ in snaps.mutate { $0 += 1 } }
        eng.start()
        let t0 = Date()
        for i in 0..<500 {
            eng.ingest(AgentEvent(kind: .claudeCode, sessionID: "burst", payload: .toolStart(ToolInfo(name: "Bash", summary: "cmd \(i)")), provenance: .hook))
        }
        let burst = Date().timeIntervalSince(t0)
        await sleepMs(350)
        check(snaps.get() <= 1 + Int(burst / 0.1) + 2, "500 events in \(String(format: "%.0f", burst * 1000)) ms coalesce into \(snaps.get()) snapshot(s)")
        eq(eng.currentSessions.first?.currentTool?.summary ?? "", "cmd 499", "...and the last state is what gets published")
        check(await waitUntil { eng.publishCount >= 1 }, "at least one snapshot published")
        let base = snaps.get()
        let t1 = Date()
        for i in 0..<250 {
            eng.ingest(AgentEvent(kind: .claudeCode, sessionID: "burst", payload: .toolStart(ToolInfo(name: "Bash", summary: "sustained \(i)")), provenance: .hook))
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        let dur = Date().timeIntervalSince(t1)
        await sleepMs(250)
        let n = snaps.get() - base
        check(Double(n) <= dur * 10 + 3, "sustained events publish at most ~10 Hz (\(n) snapshots in \(String(format: "%.2f", dur)) s)")
        check(n >= 3, "...but still keep publishing (\(n))")
        let calm = snaps.get()
        await sleepMs(250)
        eq(snaps.get(), calm, "no events: no snapshots (unchanged state is never republished)")
        eng.stop()
    }

    section("AgentEngine: expiry with an injected clock")
    do {
        let dir = makeTmp("ex")
        var cfg = engineConfig(socket: dir + "/run/agent.sock")
        let clock = Atomic(Date(timeIntervalSince1970: 1_800_000_000))
        let alive = Atomic(true)
        cfg.clock = { clock.get() }
        cfg.pidAlive = { _, _ in alive.get() }
        cfg.expireInterval = 3600
        let eng = AgentEngine(config: cfg)
        eng.start()
        var e = AgentEvent(kind: .claudeCode, sessionID: "exp", payload: .promptSubmit(prompt: "p", title: nil), provenance: .hook, pid: 31337)
        e.cwd = "/w"
        eng.ingest(e)
        eng.runExpiry()
        eq(eng.currentSessions.first?.status ?? .unknown, .running, "alive pid: still running")
        alive.set(false); clock.set(clock.get().addingTimeInterval(20))
        eng.runExpiry()
        eq(eng.currentSessions.first?.status ?? .unknown, .done, "dead pid: done")
        clock.set(clock.get().addingTimeInterval(301))
        eng.runExpiry()
        check(eng.currentSessions.isEmpty, "ended sessions are dropped after 5 minutes")
        eng.stop()
    }

    section("AgentEngine: discovery wiring")
    do {
        let base = makeTmp("ed")
        let claudeDir = base + "/claude"
        let started = Date().addingTimeInterval(-500)
        let procs = FakeProcs()
        procs.add(77, path: "/bin/zsh")      // a real process table is never empty; an empty one means the scan failed
        procs.add(8001, tty: 3, start: started, path: "/Users/x/.local/share/claude/versions/2.1.299", cwd: "/w/disc", argv: ["claude"])
        write(claudeDir + "/sessions/8001.json", registryJSON(pid: 8001, sid: "disc-1", cwd: "/w/disc", startedAt: started, status: "busy"))
        let eng = AgentEngine(config: engineConfig(socket: base + "/run/agent.sock", claudeDir: claudeDir, procs: procs, discovery: true))
        eng.start()
        check(await waitUntil { eng.currentSessions.contains(where: { $0.key.id == "disc-1" }) }, "passive discovery populates sessions with zero hooks installed")
        let s = eng.currentSessions.first(where: { $0.key.id == "disc-1" })
        eq(s?.status ?? .unknown, .running, "discovered status"); check(s?.isLive == false, "passive sessions are not live (no approvals)")
        check(await waitUntil { eng.scanCount >= 3 }, "discovery keeps polling")
        // process exits: a complete scan ends the passive session
        procs.remove(8001)
        check(await waitUntil(3) { eng.currentSessions.first(where: { $0.key.id == "disc-1" })?.status == .done }, "a vanished process ends the passive session")
        // hook arrives for a session that the registry already knows: merged, not duplicated
        procs.add(8002, tty: 4, start: started, path: "/Users/x/.local/share/claude/versions/2.1.299", cwd: "/w/two", argv: ["claude"])
        write(claudeDir + "/sessions/8002.json", registryJSON(pid: 8002, sid: "disc-2", cwd: "/w/two", startedAt: started, status: "idle"))
        check(await waitUntil { eng.currentSessions.contains(where: { $0.key.id == "disc-2" }) }, "second session discovered")
        var ev = AgentEvent(kind: .claudeCode, sessionID: "disc-2", payload: .promptSubmit(prompt: "from hook", title: nil), provenance: .hook, pid: 8002)
        ev.cwd = "/w/two"
        eng.ingest(ev)
        check(await waitUntil { eng.currentSessions.first(where: { $0.key.id == "disc-2" })?.isLive == true }, "a hook event upgrades the discovered session to live")
        eq(eng.currentSessions.filter { $0.key.id == "disc-2" }.count, 1, "...without duplicating it")
        eng.stop()
        let calls = procs.listCalls
        await sleepMs(300)
        eq(procs.listCalls, calls, "after stop() the process table is never scanned again")
    }

    section("AgentEngine: server failure does not stop discovery")
    do {
        let base = makeTmp("ef")
        mkdir(base + "/open", 0o755); chmod(base + "/open", 0o755)
        let procs = FakeProcs()
        let eng = AgentEngine(config: engineConfig(socket: base + "/open/agent.sock", claudeDir: base + "/claude", procs: procs, discovery: true))
        let errs = Atomic<[String?]>([])
        eng.onServerError = { e in errs.mutate { $0.append(e) } }
        eng.start()
        check(await waitUntil { (errs.get().last ?? nil) != nil }, "an insecure socket directory is reported as a server error")
        check((errs.get().last ?? nil)?.contains("0700") == true, "...naming the required mode: \((errs.get().last ?? nil) ?? "")")
        check(await waitUntil { eng.scanCount >= 1 }, "...while passive discovery still runs")
        eng.stop()
    }

    section("AgentEngine: optional `claude agents --json`")
    do {
        let json = "[{\"cwd\":\"/w/bg\",\"kind\":\"background\",\"startedAt\":1792388523321,\"id\":\"bg-1\",\"state\":\"working\"},{\"cwd\":\"/w/i\",\"kind\":\"interactive\",\"startedAt\":1792388523321,\"pid\":777,\"status\":\"waiting\",\"waitingFor\":\"permission prompt\",\"sessionId\":\"ia-1\",\"name\":\"Named\"},{\"id\":\"../bad\"},5,{\"id\":\"bg-2\",\"state\":\"done\"}]"
        let parsed = DiscoveryRegistry.parseClaudeAgentsJSON(Data(json.utf8))
        eq(parsed.map { $0.key.id }, ["bg-1", "ia-1", "bg-2"], "agents --json: entries parsed, unsafe/odd ones skipped")
        eq(parsed[0].status ?? .unknown, .running, "agents --json: background working -> running"); eq(parsed[0].surface ?? .unknown, .background, "agents --json: background surface")
        eq(parsed[1].status ?? .unknown, .needsPermission, "agents --json: waiting + permission prompt"); eq(parsed[1].name ?? "", "Named", "agents --json: name")
        eq(parsed[2].status ?? .unknown, .done, "agents --json: state done")
        check(DiscoveryRegistry.parseClaudeAgentsJSON(Data("garbage".utf8)).isEmpty, "agents --json: garbage gives nothing")
        let base = makeTmp("ag")
        let runner = FakeRunner()
        runner.handler = { _, _ in ProcessRunResult(status: 0, stdout: json, stderr: "", timedOut: false, launchError: nil) }
        var cfg = DiscoveryConfig(claudeDir: base + "/c", codexDir: base + "/x")
        let reg = DiscoveryRegistry(config: cfg, source: FakeProcs())
        reg.runner = runner; reg.locateClaude = { "/fake/claude" }
        _ = reg.scan()
        eq(runner.calls.get().count, 0, "default: the CLI is never spawned")
        reg.requestOnDemandCLI(); _ = reg.scan()
        eq(runner.calls.get().count, 0, "flag off: even an explicit request does not spawn it")
        cfg.allowClaudeAgentsCLI = true
        let reg2 = DiscoveryRegistry(config: cfg, source: FakeProcs())
        reg2.runner = runner; reg2.locateClaude = { "/fake/claude" }
        _ = reg2.scan()
        eq(runner.calls.get().count, 0, "flag on but no request: still nothing (never polled)")
        reg2.requestOnDemandCLI()
        let res = reg2.scan()
        eq(runner.calls.get().count, 1, "flag on + request: exactly one call")
        eq(runner.calls.get().last?.args ?? [], ["agents", "--json"], "...with fixed arguments")
        check(res.sessions.contains(where: { $0.key.id == "bg-1" }), "...its sessions are merged in")
        _ = reg2.scan()
        eq(runner.calls.get().count, 1, "the request is consumed: the next scan does not call it again")
    }
}

@MainActor
func runCenterTests() async {
    section("AgentCenter: lifecycle")
    do {
        let preview = AgentCenter.preview(sessions: [], pending: [], board: [BoardSection(title: "x")], hooks: .installed(claude: true, codex: false))
        eq(preview.board.count, 1, "preview factory: fixed data"); check(!preview.isRunning, "preview factory: nothing runs")
        let fdBase = socketFDCount()
        let base = makeTmp("ce")
        let sock = base + "/run/agent.sock"
        var cfg = AgentCenterConfig(socketPath: sock, claudeDir: base + "/claude", codexDir: base + "/codex", boardURL: URL(fileURLWithPath: base + "/board/b.json"))
        cfg.enableDiscovery = false
        cfg.boardDebounce = 0.1
        let c = AgentCenter(config: cfg)
        check(!c.isRunning && !FileManager.default.fileExists(atPath: sock) && c.engineForTesting == nil, "nothing runs and no socket exists before start()")
        c.start(); c.start()
        check(c.isRunning, "start() -> isRunning (idempotent)")
        check(FileManager.default.fileExists(atPath: sock), "start() creates the private socket")
        check(c.serverError == nil, "no server error")
        eq(c.hooksState, .notInstalled, "hooks state read at start")

        _ = await sh(hookCommand(socket: sock, blocking: false), stdin: cj("SessionStart", ["source": "startup"]))
        _ = await sh(hookCommand(socket: sock, blocking: false), stdin: cj("UserPromptSubmit", ["prompt": "build"]))
        check(await waitUntil { c.sessions.first?.status == .running }, "hook events reach the published sessions")
        eq(c.sessions.first?.projectName ?? "", "proj", "published session carries the project name")

        let t = Task { await sh(hookCommand(socket: sock, blocking: true), stdin: permEvent) }
        check(await waitUntil { c.pending.count == 1 }, "pending approval is published")
        eq(c.sessions.first?.status ?? .unknown, .needsPermission, "session shows needsPermission")
        let id = c.pending[0].id
        c.decide(id, .allowOnce)
        check(c.pending.isEmpty, "decide() removes the card immediately")
        eq(decisionBehavior((await t.value).stdout) ?? "", "allow", "decide() reaches the agent")
        check(await waitUntil { c.sessions.first?.status == .running }, "session returns to running")
        c.decide(id, .deny(message: nil))
        c.decide(UUID(), .allowOnce)
        check(true, "deciding stale or unknown ids is harmless")

        // deny + allowAlways through the center
        let t2 = Task { await sh(hookCommand(socket: sock, blocking: true), stdin: permEvent) }
        check(await waitUntil { c.pending.count == 1 }, "pending again")
        eq(c.pending[0].suggestions.first?.label ?? "", "Always allow Bash(npm test:*)", "suggestion label published")
        c.decide(c.pending[0].id, .allowAlways(suggestionIndex: 0))
        let r2 = await t2.value
        check(r2.stdout.contains("updatedPermissions"), "allowAlways reaches the agent with updatedPermissions")

        // stop with an approval pending
        let t3 = Task { await sh(hookCommand(socket: sock, blocking: true), stdin: permEvent) }
        check(await waitUntil { c.pending.count == 1 }, "pending before stop")
        c.stop()
        eq((await t3.value).stdout, "", "stop(): the pending hook gets nothing (agent falls back to its own prompt)")
        check(!c.isRunning && c.sessions.isEmpty && c.pending.isEmpty, "stop(): sessions and pending are cleared")
        check(!FileManager.default.fileExists(atPath: sock), "stop(): socket released")
        check(c.engineForTesting == nil, "stop(): the engine (timers, queues, server) is released")
        let rs = await sh(hookCommand(socket: sock, blocking: true), stdin: permEvent)
        check(rs.stdout.isEmpty && rs.status == 0, "after stop() hooks are silent no-ops")
        c.stop()
        check(true, "stop() is idempotent")
        await sleepMs(200)
        check(socketFDCount() <= fdBase, "no socket descriptors are held after stop() (\(fdBase) -> \(socketFDCount()))")

        // restart
        c.start()
        check(c.isRunning && FileManager.default.fileExists(atPath: sock), "restart after stop works")
        _ = await sh(hookCommand(socket: sock, blocking: false), stdin: cj("SessionStart", ["session_id": "again"]))
        check(await waitUntil { c.sessions.contains(where: { $0.key.id == "again" }) }, "events flow again after a restart")
        c.stop()
    }

    section("AgentCenter: errors, hooks, notices")
    do {
        let base = makeTmp("cf")
        var cfg = AgentCenterConfig(socketPath: base + "/" + String(repeating: "d", count: 120) + "/agent.sock", claudeDir: base + "/claude", codexDir: base + "/codex", boardURL: URL(fileURLWithPath: base + "/b.json"))
        cfg.enableDiscovery = false
        let c = AgentCenter(config: cfg)
        c.start()
        check(await waitUntil { c.serverError != nil }, "a too-long socket path is published as serverError")
        check(c.serverError?.contains("too long") == true, "...with an explanation (\(c.serverError ?? ""))")
        check(c.isRunning, "the center still runs (discovery would continue)")
        c.stop()
        check(c.serverError == nil, "stop() clears serverError")

        mkdir(base + "/open", 0o755); chmod(base + "/open", 0o755)
        var cfg2 = AgentCenterConfig(socketPath: base + "/open/agent.sock", claudeDir: base + "/claude", codexDir: base + "/codex", boardURL: URL(fileURLWithPath: base + "/b2.json"))
        cfg2.enableDiscovery = false
        let c2 = AgentCenter(config: cfg2)
        c2.start()
        check(await waitUntil { c2.serverError != nil }, "an insecure directory is published as serverError")
        c2.stop()

        // hooks state from the marker (read-only) and a plugged-in installer
        write(base + "/claude/settings.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"... .atoll/run/agent.sock ...\"}]}]}}")
        var cfg3 = AgentCenterConfig(socketPath: base + "/s/agent.sock", claudeDir: base + "/claude", codexDir: base + "/codex", boardURL: URL(fileURLWithPath: base + "/b3.json"))
        cfg3.enableDiscovery = false; cfg3.enableServer = false
        let c3 = AgentCenter(config: cfg3)
        eq(c3.hooksState, .notInstalled, "before start the state is the default")
        c3.start()
        eq(c3.hooksState, .installed(claude: true, codex: false), "start() reads whether Toplet's marker is present in the Claude settings")
        eq(c3.previewHookChanges(), "", "default installer: empty preview")

        final class FakeInstaller: HookInstalling {
            var installed = (false, false); var fail: String?
            func preview() -> String { "+ hook line" }
            func install(claude: Bool, codex: Bool) throws { if let f = fail { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: f]) }; installed = (claude, codex) }
            func uninstall() throws { installed = (false, false) }
            func state() -> HooksState { installed == (false, false) ? .notInstalled : .installed(claude: installed.0, codex: installed.1) }
        }
        let fi = FakeInstaller()
        c3.hookInstaller = fi
        eq(c3.previewHookChanges(), "+ hook line", "previewHookChanges() goes through the HookInstalling plug-in")
        c3.installHooks(claude: true, codex: false)
        eq(c3.hooksState, .installed(claude: true, codex: false), "installHooks() publishes the installer's state"); check(fi.installed == (true, false), "...after calling it with the selection")
        check(c3.lastNotice != nil, "...and sets a notice")
        c3.uninstallHooks()
        eq(c3.hooksState, .notInstalled, "uninstallHooks() publishes the state")
        fi.fail = "settings.json is not valid JSON"
        c3.installHooks(claude: true, codex: true)
        eq(c3.hooksState, .error("settings.json is not valid JSON"), "an installer failure becomes .error(message)")
        c3.stop()
    }

    section("AgentCenter: passive discovery, jump, notices")
    do {
        let base = makeTmp("cd")
        let claudeDir = base + "/claude"
        let started = Date().addingTimeInterval(-900)
        let apps = makeTmp("apps")
        let termExe = makeFakeApp(apps, "Terminal", bundleID: "com.apple.Terminal")
        let procs = FakeProcs()
        procs.add(10, path: termExe)
        procs.add(9001, ppid: 10, tty: 6, start: started, path: "/Users/x/.local/share/claude/versions/2.1.299", cwd: "/w/jump", argv: ["claude"])
        write(claudeDir + "/sessions/9001.json", registryJSON(pid: 9001, sid: "jump-1", cwd: "/w/jump", startedAt: started, status: "idle"))
        let scripts = FakeScripts()
        let jumper = TerminalJumper(scripts: scripts, opener: FakeOpener(), activator: FakeActivator(running: ["com.apple.Terminal"]), runner: FakeRunner(),
                                    pidAlive: { _, _ in true }, processCwd: { _ in "/w/jump" })
        var cfg = AgentCenterConfig(socketPath: base + "/run/agent.sock", claudeDir: claudeDir, codexDir: base + "/codex", boardURL: URL(fileURLWithPath: base + "/b.json"))
        cfg.processSource = procs; cfg.jumper = jumper; cfg.discoveryInterval = 0.05
        let c = AgentCenter(config: cfg)
        c.start()
        check(await waitUntil { c.sessions.contains(where: { $0.key.id == "jump-1" }) }, "passive sessions are published")
        let key = SessionKey(kind: .claudeCode, id: "jump-1")
        let calls0 = procs.listCalls
        c.refreshDiscovery()
        check(await waitUntil { procs.listCalls > calls0 }, "refreshDiscovery() scans right away")
        scripts.outcomes = [.ok("ok")]
        c.setNotice("old notice")
        c.jump(to: key)
        check(await waitUntil { c.lastNotice == nil }, "a successful jump clears the notice")
        check(scripts.ran.get().last?.contains("/dev/ttys006") == true, "the jump ran the tty script for this session")
        scripts.outcomes = [.notAuthorized]
        c.jump(to: key)
        check(await waitUntil { c.lastNotice != nil }, "a failed jump sets lastNotice")
        check(c.lastNotice?.contains("Automation") == true, "...saying why: \(c.lastNotice ?? "")")
        c.jump(to: SessionKey(kind: .claudeCode, id: "nope"))
        check(c.lastNotice?.contains("no longer") == true, "jumping to an unknown session sets a notice")
        let calls1 = procs.listCalls
        c.stop()
        await sleepMs(300)
        eq(procs.listCalls, calls1, "stop() ends discovery polling completely")
        check(c.sessions.isEmpty, "stop() clears the published sessions")
    }

    section("AgentCenter: board")
    do {
        let base = makeTmp("cb")
        let boardURL = URL(fileURLWithPath: base + "/Toplet/agents-board.json")
        var cfg = AgentCenterConfig(socketPath: base + "/run/agent.sock", claudeDir: base + "/c", codexDir: base + "/x", boardURL: boardURL)
        cfg.enableDiscovery = false; cfg.enableServer = false; cfg.boardDebounce = 0.1
        let c = AgentCenter(config: cfg)
        c.start()
        let s1 = c.addSection(title: "  Inbox\u{202E} ")
        let s2 = c.addSection(title: "Doing")
        eq(c.board.map { $0.title }, ["Inbox", "Doing"], "sections are added with sanitised titles")
        eq(c.addSection(title: "  \u{200B}  ") != s1, true, "an empty title still gets a (placeholder) section")
        c.deleteSection(c.board[2].id)
        let t1 = c.addTask(in: s1, title: "Write tests")!
        let t2 = c.addTask(in: s1, title: "Ship it")!
        check(c.addTask(in: s1, title: "   ") == nil, "an empty task title is refused")
        check(c.addTask(in: UUID(), title: "orphan") == nil, "a task in an unknown section is refused")
        c.updateTask(t1, title: "Write more tests", notes: "line\u{0}1\nline2")
        eq(c.board[0].tasks[0].title, "Write more tests", "updateTask: title"); eq(c.board[0].tasks[0].notes, "line1\nline2", "updateTask: sanitised notes")
        c.updateTask(t1, title: "   ")
        eq(c.board[0].tasks[0].title, "Write more tests", "updateTask: an empty title is ignored")
        c.toggleTask(t2); check(c.board[0].tasks[1].isDone, "toggleTask")
        c.toggleCollapsed(s2); check(c.board[1].isCollapsed, "toggleCollapsed")
        c.renameSection(s2, to: "In progress"); eq(c.board[1].title, "In progress", "renameSection")
        c.renameSection(s2, to: "  "); eq(c.board[1].title, "In progress", "renameSection ignores an empty title")
        c.moveTask(t1, toSection: s2, at: 0)
        eq(c.board[0].tasks.map { $0.id }, [t2], "moveTask: removed from the old section"); eq(c.board[1].tasks.map { $0.id }, [t1], "moveTask: added to the new one")
        c.moveTask(t2, toSection: s2, at: 99)
        eq(c.board[1].tasks.map { $0.id }, [t1, t2], "moveTask: index is clamped")
        c.moveTask(t2, toSection: s2, at: -5)
        eq(c.board[1].tasks.map { $0.id }, [t2, t1], "moveTask: negative index is clamped")
        c.moveTask(t2, toSection: UUID(), at: 0)
        eq(c.board[1].tasks.count, 2, "moveTask to an unknown section changes nothing")
        c.deleteTask(UUID()); c.toggleTask(UUID()); c.updateTask(UUID(), title: "x"); c.deleteSection(UUID()); c.toggleCollapsed(UUID())
        check(true, "operations on unknown ids are harmless")
        await sleepMs(500)
        let onDisk = BoardStore(url: boardURL).load()
        func ms(_ b: [BoardSection]) -> [BoardSection] {      // the file stores milliseconds
            b.map { var s = $0; s.tasks = s.tasks.map { var t = $0; t.createdAt = Date(timeIntervalSince1970: (t.createdAt.timeIntervalSince1970 * 1000).rounded() / 1000); return t }; return s }
        }
        eq(onDisk, ms(c.board), "every change is persisted (debounced), dates included (to the millisecond)")
        c.stop()
        // reload in a new center
        let c2 = AgentCenter(config: cfg)
        c2.start()
        eq(c2.board, onDisk, "the board is loaded at start()")
        c2.deleteTask(t1)
        c2.stop()
        eq(BoardStore(url: boardURL).load().flatMap { $0.tasks }.count, 1, "stop() flushes pending changes")
        // bounds through the API
        let cb = AgentCenter(config: { var x = cfg; x.boardURL = URL(fileURLWithPath: base + "/big.json"); return x }())
        cb.start()
        for i in 0..<205 { cb.addSection(title: "S\(i)") }
        eq(cb.board.count, 200, "at most 200 sections through the API")
        check(cb.lastNotice?.contains("full") == true, "...with a notice")
        let sec = cb.board[0].id
        for i in 0..<2005 { _ = cb.addTask(in: sec, title: "T\(i)") }
        eq(cb.board.reduce(0) { $0 + $1.tasks.count }, 2000, "at most 2000 tasks through the API")
        cb.stop()
        // corrupt board file at start
        write(base + "/corrupt.json", "{{{{ nope")
        var cfgC = cfg; cfgC.boardURL = URL(fileURLWithPath: base + "/corrupt.json")
        let cc = AgentCenter(config: cfgC)
        cc.start()
        eq(cc.board, [], "a corrupt board starts empty"); check(cc.lastNotice?.contains("corrupt") == true, "...and says a copy was kept")
        check(FileManager.default.fileExists(atPath: base + "/corrupt.json.corrupt"), "...the .corrupt copy exists")
        cc.stop()
    }

    section("AgentCenter: quick tasks")
    do {
        let base = makeTmp("cq")
        let work = makeTmp("wk")
        let runner = FakeRunner()
        runner.handler = { _, _ in ProcessRunResult(status: 0, stdout: "started 0198aaaa-bbbb-7ccc-8ddd-eeeeffff0003\n", stderr: "", timedOut: false, launchError: nil) }
        let opener = FakeOpener()
        var cfg = AgentCenterConfig(socketPath: base + "/run/agent.sock", claudeDir: base + "/c", codexDir: base + "/x", boardURL: URL(fileURLWithPath: base + "/b.json"))
        cfg.enableDiscovery = false; cfg.enableServer = false
        cfg.quickRunner = QuickTaskRunner(runner: runner, opener: opener, locateClaude: { "/fake/claude" })
        let c = AgentCenter(config: cfg)
        c.start()
        let sec = c.addSection(title: "Todo")
        let tid = c.addTask(in: sec, title: "Refactor the parser")!
        c.startQuickTask(tid, with: .claudeCode, cwd: URL(fileURLWithPath: work, isDirectory: true))
        check(await waitUntil { c.board[0].tasks[0].linkedSessionID != nil }, "claude: the started session is linked to the task")
        eq(c.board[0].tasks[0].linkedSessionID ?? "", "claude:0198aaaa-bbbb-7ccc-8ddd-eeeeffff0003", "claude: link uses the AgentSession id format")
        eq(c.board[0].tasks[0].agent ?? .codex, .claudeCode, "claude: agent recorded")
        check(c.lastNotice?.contains("Started") == true, "claude: a notice says it started")
        eq(runner.calls.get().last?.args ?? [], ["--bg", "Refactor the parser"], "claude: only --bg <title>")
        c.startQuickTask(tid, with: .codex, cwd: URL(fileURLWithPath: work, isDirectory: true))
        check(await waitUntil { opener.opened.get().count == 1 }, "codex: the deep link is opened")
        eq(c.board[0].tasks[0].agent ?? .claudeCode, .codex, "codex: agent recorded")
        check(opener.opened.get()[0].absoluteString.contains("prompt=Refactor%20the%20parser"), "codex: prompt is percent-encoded")
        let t2 = c.addTask(in: sec, title: "Will fail")!
        runner.handler = { _, _ in ProcessRunResult(status: 1, stdout: "", stderr: "nope", timedOut: false, launchError: nil) }
        c.startQuickTask(t2, with: .claudeCode, cwd: URL(fileURLWithPath: work, isDirectory: true))
        check(await waitUntil { c.lastNotice?.contains("failed") == true }, "a failed start sets a notice")
        check(c.board[0].tasks[1].agent == nil && c.board[0].tasks[1].linkedSessionID == nil, "...and does not link anything")
        c.startQuickTask(UUID(), with: .claudeCode, cwd: URL(fileURLWithPath: work))
        check(true, "an unknown task id is ignored")
        c.stop()
    }

    section("AgentCenter: publishing is coalesced")
    do {
        let base = makeTmp("cp")
        var cfg = AgentCenterConfig(socketPath: base + "/run/agent.sock", claudeDir: base + "/c", codexDir: base + "/x", boardURL: URL(fileURLWithPath: base + "/b.json"))
        cfg.enableDiscovery = false
        let c = AgentCenter(config: cfg)
        c.start()
        var changes = 0
        let sub = c.$sessions.dropFirst().sink { _ in changes += 1 }
        guard let eng = c.engineForTesting else { check(false, "engine missing"); return }
        let t0 = Date()
        for i in 0..<400 {
            eng.ingest(AgentEvent(kind: .claudeCode, sessionID: "p\(i % 5)", payload: .toolStart(ToolInfo(name: "Bash", summary: "c\(i)")), provenance: .hook))
        }
        let burst = Date().timeIntervalSince(t0)
        await sleepMs(400)
        check(changes <= 1 + Int(burst / 0.1) + 2, "400 events in \(String(format: "%.0f", burst * 1000)) ms reach the UI as \(changes) update(s)")
        eq(c.sessions.count, 5, "...with the final state")
        sub.cancel()
        c.stop()
    }
}
