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

// Passive (P0) discovery, zero install: ~/.claude/sessions/*.json registry + libproc process scan + tail-only
// transcript/rollout parsing, merged into DiscoveredSession values (research section 4). Read-only. All paths injectable.

// MARK: - Known host apps

enum HostApps {
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "io.alacritty", "org.alacritty", "co.zeit.hyper", "com.raphaelamorim.rio",
    ]
    static let vscodeLike: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "com.vscodium", "com.visualstudio.code.oss",
    ]
    static let codexApps: Set<String> = ["com.openai.codex", "com.openai.chat"]
    static let claudeDesktop = "com.anthropic.claudefordesktop"

    static func surface(for bundleID: String?) -> Surface? {
        guard let b = bundleID else { return nil }
        if terminals.contains(b) { return .terminal }
        if vscodeLike.contains(b) { return .vscode }
        if b.hasPrefix("com.jetbrains.") { return .jetbrains }
        if b == "com.apple.dt.Xcode" { return .xcode }
        if b == claudeDesktop || codexApps.contains(b) || b.hasPrefix("com.anthropic.claude") { return .desktopApp }
        return nil
    }

    static func surface(entrypoint: String?, kind: String?) -> Surface? {
        if kind?.lowercased() == "background" { return .background }
        guard let e = entrypoint?.lowercased() else { return nil }
        if e.contains("desktop") { return .desktopApp }
        if e.contains("vscode") || e.contains("vs-code") { return .vscode }
        if e.contains("jetbrains") || e.contains("intellij") { return .jetbrains }
        if e.contains("sdk") { return .headless }
        if e == "cli" || e.contains("terminal") { return .terminal }
        return nil
    }
}

// MARK: - Config / result

struct DiscoveryConfig {
    var claudeDir: String
    var codexDir: String
    var uid: uid_t
    /// Optional single on-demand `claude agents --json` call. Default off; never polled in a loop.
    var allowClaudeAgentsCLI = false

    init(claudeDir: String? = nil, codexDir: String? = nil, uid: uid_t = getuid()) {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        self.claudeDir = claudeDir ?? env["CLAUDE_CONFIG_DIR"] ?? (home as NSString).appendingPathComponent(".claude")
        self.codexDir = codexDir ?? env["CODEX_HOME"] ?? (home as NSString).appendingPathComponent(".codex")
        self.uid = uid
    }
}

struct DiscoveryResult: Equatable {
    var sessions: [DiscoveredSession]
    var complete: Bool
    var notes: [String]
}

struct RegistryEntry: Equatable {
    var pid: Int32
    var sessionID: String
    var cwd: String
    var name: String?
    var status: String?
    var waitingFor: String?
    var statusUpdatedAt: Date?
    var startedAt: Date?
    var kind: String?
    var entrypoint: String?
    var version: String?
}

// MARK: - Registry + merge

final class DiscoveryRegistry {
    static let maxRegistryFiles = 256
    static let maxRegistryFileBytes = 64 * 1024

    let config: DiscoveryConfig
    let scanner: ProcessScanner
    let source: ProcessSource
    let tail: TranscriptTail
    let now: () -> Date
    /// tty -> tmux jump target (resolved via `tmux list-panes`); injectable for tests.
    var tmuxResolver: (String) -> JumpTarget? = { _ in nil }

    private var transcriptIndex: [String: String] = [:]   // claude session id -> transcript path
    /// Passive-mode tunables (busy window, idle drop ...).
    var policy = PassivePolicy.default
    private let cliLock = NSLock()
    private var cliRequested = false
    /// Runs the optional single on-demand `claude agents --json` call (only when `config.allowClaudeAgentsCLI`).
    var runner: ProcessRunning = SystemProcessRunner()
    var locateClaude: () -> String? = { ExecutableLocator.find("claude") }

    /// Asks the next scan to include ONE `claude agents --json` call (the supervised read API). No-op unless the flag is on.
    func requestOnDemandCLI() { cliLock.lock(); cliRequested = config.allowClaudeAgentsCLI; cliLock.unlock() }
    private func takeCLIRequest() -> Bool { cliLock.lock(); defer { cliLock.unlock() }; let r = cliRequested; cliRequested = false; return r }

    init(config: DiscoveryConfig = DiscoveryConfig(), source: ProcessSource = LibprocSource(), apps: AppResolver = PlistAppResolver(),
         tail: TranscriptTail = TranscriptTail(), now: @escaping () -> Date = Date.init) {
        self.config = config; self.source = source; self.tail = tail; self.now = now
        self.scanner = ProcessScanner(source: source, uid: config.uid, apps: apps)
    }

    static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\\z")
    static func isSafeID(_ s: String) -> Bool {
        idPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Registry files

    func readRegistry() -> [RegistryEntry] {
        let dir = (config.claudeDir as NSString).appendingPathComponent("sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [RegistryEntry] = []
        for name in names.sorted().prefix(DiscoveryRegistry.maxRegistryFiles) where name.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(name)
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0, st.st_size <= DiscoveryRegistry.maxRegistryFileBytes,
                  st.st_uid == config.uid else { continue }
            guard let data = FileManager.default.contents(atPath: path), let e = DiscoveryRegistry.parseRegistryEntry(data) else { continue }
            out.append(e)
        }
        return out
    }

    /// Defensive: required keys pid, sessionId, cwd; everything else optional; unknown keys ignored.
    static func parseRegistryEntry(_ data: Data) -> RegistryEntry? {
        guard let o = JSONField.parseObject(data) else { return nil }
        guard let pidInt = JSONField.int(o, "pid"), pidInt > 1, pidInt <= Int(Int32.max),
              let sid = JSONField.nonEmptyString(o, "sessionId", "session_id"), isSafeID(sid) else { return nil }
        func date(_ keys: String...) -> Date? {
            for k in keys {
                if let d = JSONField.double(o, k), d > 0 { return Date(timeIntervalSince1970: d > 1e11 ? d / 1000 : d) }
                if let s = o[k] as? String, let dt = JSONField.date(s) { return dt }
            }
            return nil
        }
        return RegistryEntry(pid: Int32(pidInt), sessionID: sid,
                             cwd: AgentText.clean(JSONField.string(o, "cwd") ?? "", max: 512),
                             name: AgentText.cleanOptional(JSONField.string(o, "name"), max: 120),
                             status: JSONField.string(o, "status")?.lowercased(),
                             waitingFor: AgentText.cleanOptional(JSONField.string(o, "waitingFor", "waiting_for"), max: 60),
                             statusUpdatedAt: date("statusUpdatedAt", "updatedAt"),
                             startedAt: date("startedAt"),
                             kind: JSONField.string(o, "kind")?.lowercased(),
                             entrypoint: JSONField.string(o, "entrypoint"),
                             version: AgentText.cleanOptional(JSONField.string(o, "version"), max: 32))
    }

    static func mapStatus(_ raw: String?, waitingFor: String?) -> (SessionStatus, String?)? {
        guard let r = raw?.lowercased() else { return nil }
        switch r {
        case "busy", "working", "running": return (.running, nil)
        case "idle", "done": return (.idle, nil)
        case "waiting", "blocked":
            if (waitingFor ?? "").lowercased().contains("permission") { return (.needsPermission, "permission prompt") }
            return (.waitingInput, waitingFor ?? "input needed")
        default: return nil
        }
    }

    // MARK: Scan

    func scan() -> DiscoveryResult {
        let t = now()
        let proc = scanner.scan()
        var notes: [String] = []
        var out: [DiscoveredSession] = []
        var claimedPids = Set<Int32>()
        var claimedTranscripts = Set<String>()

        let agentByPid = Dictionary(uniqueKeysWithValues: proc.agents.map { ($0.pid, $0) })

        // 1. Claude registry (authoritative for pid -> session, status)
        for e in readRegistry() {
            guard let b = source.basic(e.pid), b.uid == config.uid else { continue }               // dead or foreign
            // PID reuse: a process that started well after the session claims to have started is not that session.
            if let sa = e.startedAt, b.start.timeIntervalSince(sa) > 60 { continue }
            claimedPids.insert(e.pid)
            var d = DiscoveredSession(key: SessionKey(kind: .claudeCode, id: e.sessionID), provenance: .registry)
            let ap = agentByPid[e.pid]
            let cwd = e.cwd.hasPrefix("/") ? e.cwd : (ap?.cwd ?? source.cwd(e.pid) ?? e.cwd)
            d.cwd = cwd
            d.name = e.name
            d.pid = e.pid
            d.processStart = b.start
            d.tty = b.ttyDevice.flatMap { source.ttyName($0) }
            let host = ap.map { ($0.hostBundleID, $0.underTmux) } ?? scanner.hostApp(ofPid: e.pid)
            d.hostAppBundleID = host.0 ?? (HostApps.surface(entrypoint: e.entrypoint, kind: e.kind) == .desktopApp ? HostApps.claudeDesktop : nil)
            d.surface = HostApps.surface(entrypoint: e.entrypoint, kind: e.kind) ?? HostApps.surface(for: host.0) ?? (d.tty != nil ? .terminal : .unknown)
            d.jump = makeJump(kind: .claudeCode, id: e.sessionID, host: d.hostAppBundleID, tty: d.tty, underTmux: host.1, surface: d.surface)
            if let (st, wf) = DiscoveryRegistry.mapStatus(e.status, waitingFor: e.waitingFor) {
                d.status = st; d.waitingFor = wf; d.statusProvenance = .registry; d.statusSince = e.statusUpdatedAt
            }
            d.lastActivity = e.statusUpdatedAt
            if let path = claudeTranscriptPath(sessionID: e.sessionID, cwd: cwd), let sum = tail.summarize(path: path, kind: .claudeCode, sessionID: e.sessionID) {
                claimedTranscripts.insert(e.sessionID)
                applySummary(sum, to: &d, path: path, now: t, statusIfMissing: true)
                d.subagents = claudeSubagents(transcriptPath: path, now: t)
            }
            out.append(d)
        }

        // 2. Claude processes with no registry file. Claude Code appends to its transcript and closes it, so no fd stays
        //    open (empirical finding credited to realfishsam/agent-notch, MIT; our own code): map by cwd to
        //    projects/<slug>/ and, with several sessions in one cwd, pair by transcript birth time vs process start.
        //    Interactive sessions have a controlling tty; processes without one are excluded.
        let loneClaude = proc.agents.filter { $0.kind == .claudeCode && !claimedPids.contains($0.pid) && $0.tty != nil }
        var assigned: [Int32: (id: String, path: String)] = [:]
        for p in loneClaude {
            if let hit = openClaudeTranscript(pid: p.pid), !claimedTranscripts.contains(hit.id) { assigned[p.pid] = hit; claimedTranscripts.insert(hit.id) }
        }
        let byCwd = Dictionary(grouping: loneClaude.filter { assigned[$0.pid] == nil && $0.cwd != nil }, by: { $0.cwd! })
        for (cwd, group) in byCwd.sorted(by: { $0.key < $1.key }) {
            let procs = group.sorted { $0.start < $1.start }
            var pool = claudeTranscripts(cwd: cwd, notBefore: procs[0].start.addingTimeInterval(-300), excluding: claimedTranscripts)
            if procs.count == 1 {
                if let newest = pool.max(by: { $0.mtime < $1.mtime }) { assigned[procs[0].pid] = (newest.id, newest.path); claimedTranscripts.insert(newest.id) }
            } else {
                for p in procs {
                    guard let best = pool.min(by: { abs($0.birth.timeIntervalSince(p.start)) < abs($1.birth.timeIntervalSince(p.start)) }),
                          abs(best.birth.timeIntervalSince(p.start)) < 600 else { continue }
                    assigned[p.pid] = (best.id, best.path); claimedTranscripts.insert(best.id)
                    pool.removeAll { $0.path == best.path }
                }
            }
        }
        for p in loneClaude {
            var d = DiscoveredSession(key: SessionKey(kind: .claudeCode, id: "pid:\(p.pid)"), provenance: .processScan, cwd: p.cwd ?? "")
            fill(&d, from: p)
            if let (id, path) = assigned[p.pid], let sum = tail.summarize(path: path, kind: .claudeCode, sessionID: id) {
                d.key = SessionKey(kind: .claudeCode, id: id)
                applySummary(sum, to: &d, path: path, now: t, statusIfMissing: true)
                d.subagents = claudeSubagents(transcriptPath: path, now: t)
            }
            out.append(d)
        }

        // 3. Codex processes <-> rollouts. Codex keeps its rollout open, so the process's open files give the EXACT
        //    mapping (idea credited to agent-notch; libproc instead of lsof); cwd/start-time matching is the fallback.
        let codexProcs = proc.agents.filter { $0.kind == .codex && $0.tty != nil }
        let rollouts = candidateRollouts(procs: codexProcs, now: t)
        var claimedRollouts = Set<String>()
        var exact: [Int32: Rollout] = [:]
        for p in codexProcs.sorted(by: { $0.start < $1.start }) {
            if let r = openRollout(pid: p.pid), !claimedRollouts.contains(r.id) { exact[p.pid] = r; claimedRollouts.insert(r.id) }
        }
        for p in codexProcs.sorted(by: { $0.start < $1.start }) {
            var d = DiscoveredSession(key: SessionKey(kind: .codex, id: "pid:\(p.pid)"), provenance: .processScan, cwd: p.cwd ?? "")
            fill(&d, from: p)
            var match = exact[p.pid]
            if match == nil, let r = bestRollout(for: p, in: rollouts, claimed: claimedRollouts, siblings: codexProcs.filter { $0.cwd == p.cwd }.count) {
                claimedRollouts.insert(r.id); match = r
            }
            if let r = match {
                d.key = SessionKey(kind: .codex, id: r.id)
                if let sum = tail.summarize(path: r.path, kind: .codex, sessionID: r.id) {
                    applySummary(sum, to: &d, path: r.path, now: t, statusIfMissing: true)
                    if let n = sum.note { notes.append(n) }
                }
                d.parentID = r.parentID
                d.jump = makeJump(kind: .codex, id: r.id, host: d.hostAppBundleID, tty: d.tty, underTmux: p.underTmux, surface: d.surface)
            }
            out.append(d)
        }
        // Recently active rollouts without a process of ours (e.g. the Codex desktop app hosts threads in one process,
        // and subagent threads run inside their parent's process).
        var extra = 0
        for r in rollouts.sorted(by: { $0.mtime > $1.mtime }) where !claimedRollouts.contains(r.id) && extra < 8 {
            guard t.timeIntervalSince(r.mtime) < 300 else { continue }
            guard let sum = tail.summarize(path: r.path, kind: .codex, sessionID: r.id), sum.compressed == false else { continue }
            if sum.status == .done { continue }
            var d = DiscoveredSession(key: SessionKey(kind: .codex, id: r.id), provenance: .rollout, cwd: sum.cwd ?? r.cwd ?? "")
            applySummary(sum, to: &d, path: r.path, now: t, statusIfMissing: true)
            d.surface = .unknown
            d.parentID = r.parentID
            d.jump = makeJump(kind: .codex, id: r.id, host: nil, tty: nil, underTmux: false, surface: .desktopApp)
            out.append(d)
            extra += 1
        }

        // A live process we know nothing else about: alive but no activity data.
        for i in out.indices where out[i].status == nil && out[i].pid != nil {
            out[i].status = .idle; out[i].statusProvenance = .processScan; out[i].statusDetail = PassivePolicy.estimatedDetail
        }
        // Idle for longer than `idleDrop`: not worth listing (the reducer drops them too; this avoids re-adding them each scan).
        out.removeAll { d in
            guard let la = d.lastActivity, t.timeIntervalSince(la) > policy.idleDrop else { return false }
            return d.status == nil || d.status == .idle
        }

        if takeCLIRequest(), let claude = locateClaude() {
            let r = runner.run(executable: claude, arguments: ["agents", "--json"], cwd: nil, timeout: 8, maxOutput: 512 * 1024)
            if r.succeeded {
                let known = Set(out.map { $0.key.id })
                for d in DiscoveryRegistry.parseClaudeAgentsJSON(Data(r.stdout.utf8)) where !known.contains(d.key.id) { out.append(d) }
            } else { notes.append("claude agents --json did not answer") }
        }
        return DiscoveryResult(sessions: out, complete: proc.processCount > 0, notes: Array(Set(notes)).sorted())
    }

    // MARK: claude agents --json (official, supervised read API; research 2.5)

    /// `[{cwd, kind, startedAt, id?, state?, pid?, status?, waitingFor?, sessionId?, name?}]`. Defensive: anything odd is skipped.
    static func parseClaudeAgentsJSON(_ data: Data) -> [DiscoveredSession] {
        guard data.count < 1 << 20, let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        var out: [DiscoveredSession] = []
        for item in arr.prefix(200) {
            guard let o = item as? [String: Any] else { continue }
            guard let id = JSONField.nonEmptyString(o, "sessionId", "session_id") ?? JSONField.nonEmptyString(o, "id"), isSafeID(id) else { continue }
            var d = DiscoveredSession(key: SessionKey(kind: .claudeCode, id: id), provenance: .registry)
            d.cwd = AgentText.clean(JSONField.string(o, "cwd") ?? "", max: 512)
            d.name = AgentText.cleanOptional(JSONField.string(o, "name"), max: 120)
            if let pid = JSONField.int(o, "pid"), pid > 1, pid <= Int(Int32.max) { d.pid = Int32(pid) }
            if let t = JSONField.double(o, "startedAt"), t > 0 { d.processStart = nil; d.lastActivity = Date(timeIntervalSince1970: t > 1e11 ? t / 1000 : t) }
            if (JSONField.string(o, "kind") ?? "").lowercased() == "background" { d.surface = .background }
            let waiting = AgentText.cleanOptional(JSONField.string(o, "waitingFor"), max: 60)
            if d.pid != nil, let (st, wf) = mapStatus(JSONField.string(o, "status"), waitingFor: waiting) { d.status = st; d.waitingFor = wf }
            else {
                switch (JSONField.string(o, "state") ?? "").lowercased() {
                case "working": d.status = .running
                case "blocked": d.status = (waiting ?? "").lowercased().contains("permission") ? .needsPermission : .waitingInput; d.waitingFor = waiting
                case "done": d.status = .done
                case "failed": d.status = .failed
                case "stopped": d.status = .stopped
                default: break
                }
            }
            out.append(d)
        }
        return out
    }

    // MARK: Helpers

    private func fill(_ d: inout DiscoveredSession, from p: AgentProcess) {
        d.pid = p.pid; d.processStart = p.start; d.tty = p.tty
        d.hostAppBundleID = p.hostBundleID
        d.surface = HostApps.surface(for: p.hostBundleID) ?? (p.tty != nil || p.underTmux ? .terminal : .unknown)
        d.jump = makeJump(kind: p.kind, id: d.key.id, host: p.hostBundleID, tty: p.tty, underTmux: p.underTmux, surface: d.surface)
        d.lastActivity = nil
    }

    private func applySummary(_ s: TranscriptSummary, to d: inout DiscoveredSession, path: String, now: Date, statusIfMissing: Bool) {
        d.textProvenance = s.kind == .codex ? .rollout : .transcript
        // Title = the USER's latest prompt, not the agent's chatter. The transcript's own title (ai-title) only fills the name.
        d.title = s.lastPrompt ?? s.title
        if d.name == nil, s.kind == .claudeCode { d.name = s.title }
        d.lastPrompt = s.lastPrompt
        d.lastAssistantText = s.lastAssistantText
        d.tasks = s.tasks
        d.model = s.model                                     // model string from the transcript tail
        d.usage = s.usage
        d.transcriptPath = path
        d.fileMTime = s.fileMTime
        if d.cwd.isEmpty, let c = s.cwd { d.cwd = c }
        if d.lastActivity == nil { d.lastActivity = s.fileMTime ?? s.lastEventAt }
        if s.compressed { d.note = s.note }
        if d.status == nil, statusIfMissing {
            let prov: Provenance = s.kind == .codex ? .rollout : .transcript
            let (st, wf) = DiscoveryRegistry.passiveStatus(now: now, activity: s.fileMTime ?? s.lastEventAt, summaryStatus: s.status,
                                                          summaryWaiting: s.waitingFor, turnEnded: s.turnEnded, policy: policy)
            d.status = st; d.waitingFor = wf; d.statusProvenance = prov
            d.statusSince = s.fileMTime ?? s.lastEventAt
            d.statusDetail = PassivePolicy.estimatedDetail
        }
    }

    /// Busy/idle hybrid for sessions without a hook or registry status: process alive and the transcript/rollout written
    /// within `busyWindow` (30 s) => running; alive but quiet => idle. A rollout-inferred "waiting for you" is kept as is.
    /// LIMITATION ("afterglow"): running lingers up to ~30 s after the agent finishes, and a long silent tool run reads
    /// as idle. A live hook status always overrides this estimate.
    static func passiveStatus(now: Date, activity: Date?, summaryStatus: SessionStatus?, summaryWaiting: String?, turnEnded: Bool = false, policy: PassivePolicy) -> (SessionStatus, String?) {
        if let st = summaryStatus, st == .needsPermission || st == .waitingInput { return (st, summaryWaiting) }
        if turnEnded { return (.idle, summaryWaiting == "interrupted" ? summaryWaiting : nil) }   // the file itself says the turn is over
        if let a = activity, now.timeIntervalSince(a) < policy.busyWindow { return (.running, nil) }
        return (.idle, nil)
    }

    func makeJump(kind: AgentKind, id: String, host: String?, tty: String?, underTmux: Bool, surface: Surface?) -> JumpTarget? {
        if underTmux, let tty = tty, let t = tmuxResolver(tty) { return t }
        if kind == .codex, !id.hasPrefix("pid:"), DiscoveryRegistry.isSafeID(id),
           (host.map { HostApps.codexApps.contains($0) } ?? false) || surface == .desktopApp,
           let url = URL(string: "codex://threads/\(id)") { return .deepLink(url) }
        if let h = host {
            if HostApps.terminals.contains(h) { return .terminal(bundleID: h, tty: tty) }
            return .app(bundleID: h)
        }
        return nil
    }

    // MARK: Claude transcripts

    static func slug(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { s -> Character in
            (s.isASCII && (s.properties.isAlphabetic || (s.value >= 48 && s.value <= 57))) ? Character(s) : "-"
        })
    }

    private var projectsDir: String { (config.claudeDir as NSString).appendingPathComponent("projects") }

    func claudeTranscriptPath(sessionID: String, cwd: String) -> String? {
        guard DiscoveryRegistry.isSafeID(sessionID) else { return nil }
        if let c = transcriptIndex[sessionID], FileManager.default.fileExists(atPath: c) { return c }
        let direct = (projectsDir as NSString).appendingPathComponent(DiscoveryRegistry.slug(cwd) + "/" + sessionID + ".jsonl")
        if FileManager.default.fileExists(atPath: direct) { transcriptIndex[sessionID] = direct; return direct }
        // Long paths are truncated + hashed by Claude: fall back to scanning project dirs (bounded).
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return nil }
        for d in dirs.prefix(500) {
            let p = (projectsDir as NSString).appendingPathComponent(d + "/" + sessionID + ".jsonl")
            if FileManager.default.fileExists(atPath: p) { transcriptIndex[sessionID] = p; return p }
        }
        return nil
    }

    static func birthTime(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec) + TimeInterval(st.st_birthtimespec.tv_nsec) / 1e9)
    }

    struct ClaudeTranscript { var id: String; var path: String; var mtime: Date; var birth: Date }

    private func claudeTranscripts(cwd: String, notBefore: Date, excluding: Set<String>) -> [ClaudeTranscript] {
        let dir = (projectsDir as NSString).appendingPathComponent(DiscoveryRegistry.slug(cwd))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [ClaudeTranscript] = []
        for n in names.prefix(400) where n.hasSuffix(".jsonl") {
            let id = String(n.dropLast(6))
            let path = (dir as NSString).appendingPathComponent(n)
            guard DiscoveryRegistry.isSafeID(id), !excluding.contains(id), let m = DiscoveryRegistry.mtime(path), m >= notBefore else { continue }
            out.append(ClaudeTranscript(id: id, path: path, mtime: m, birth: DiscoveryRegistry.birthTime(path) ?? m))
        }
        return out
    }

    /// If Claude does hold its transcript open (not observed, but cheap to check), that is an exact answer.
    private func openClaudeTranscript(pid: Int32) -> (id: String, path: String)? {
        let root = realPath(projectsDir) + "/"
        for p in source.openVnodePaths(pid) where p.hasPrefix(root) && p.hasSuffix(".jsonl") {
            let id = String(((p as NSString).lastPathComponent as NSString).deletingPathExtension)
            if DiscoveryRegistry.isSafeID(id), !p.contains("/subagents/") { return (id, p) }
        }
        return nil
    }

    /// `<session>/subagents/agent-*.jsonl` (Claude Code subagent transcripts), newest 8 within the idle window.
    func claudeSubagents(transcriptPath: String, now: Date) -> [Subagent]? {
        let dir = (transcriptPath as NSString).deletingPathExtension + "/subagents"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var items: [(id: String, path: String, mtime: Date)] = []
        for n in names.prefix(400) where n.hasPrefix("agent-") && n.hasSuffix(".jsonl") {
            let id = String(n.dropFirst(6).dropLast(6))
            let path = dir + "/" + n
            guard DiscoveryRegistry.isSafeID(id), let m = DiscoveryRegistry.mtime(path), now.timeIntervalSince(m) < policy.idleDrop else { continue }
            items.append((id, path, m))
        }
        items.sort { $0.mtime > $1.mtime }
        return items.prefix(8).map { it in
            let running = now.timeIntervalSince(it.mtime) < policy.busyWindow
            let sum = tail.summarize(path: it.path, kind: .claudeCode, sessionID: it.id, includeSidechain: true)
            return Subagent(id: it.id, type: nil, status: running ? .running : .done, startedAt: DiscoveryRegistry.birthTime(it.path) ?? it.mtime,
                            currentTool: nil, lastText: sum?.lastAssistantText)
        }
    }

    static func mtime(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }

    // MARK: Codex rollouts

    struct Rollout: Equatable {
        var path: String
        var id: String
        var mtime: Date
        var cwd: String?
        var startedAt: Date?
        var compressed: Bool
        var parentID: String?
    }

    static let rolloutPattern = try! NSRegularExpression(pattern: "^rollout-.*-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\\.jsonl(\\.zst)?$")

    static func rolloutID(fromFileName n: String) -> (id: String, compressed: Bool)? {
        guard let m = rolloutPattern.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)), let r = Range(m.range(at: 1), in: n) else { return nil }
        return (String(n[r]), m.range(at: 2).location != NSNotFound)
    }

    /// Date directories to look at: today/yesterday/day-before (local and UTC) plus each process's start day.
    func rolloutDayDirs(procs: [AgentProcess], now: Date) -> [String] {
        let base = (config.codexDir as NSString).appendingPathComponent("sessions")
        var days = Set<String>()
        var dates: [Date] = (0..<3).map { now.addingTimeInterval(-Double($0) * 86400) }
        dates += procs.map { $0.start }
        for d in dates {
            for tz in [TimeZone.current, TimeZone(identifier: "UTC")!] {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
                let c = cal.dateComponents([.year, .month, .day], from: d)
                days.insert(String(format: "%@/%04d/%02d/%02d", base, c.year ?? 0, c.month ?? 0, c.day ?? 0))
            }
        }
        return days.sorted()
    }

    func candidateRollouts(procs: [AgentProcess], now: Date) -> [Rollout] {
        var out: [Rollout] = []
        for dir in rolloutDayDirs(procs: procs, now: now) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            var dayItems: [Rollout] = []
            for n in names {
                guard let (id, comp) = DiscoveryRegistry.rolloutID(fromFileName: n) else { continue }
                let path = (dir as NSString).appendingPathComponent(n)
                guard let m = DiscoveryRegistry.mtime(path) else { continue }
                dayItems.append(Rollout(path: path, id: id, mtime: m, cwd: nil, startedAt: nil, compressed: comp))
            }
            for var r in dayItems.sorted(by: { $0.mtime > $1.mtime }).prefix(200) {
                if !r.compressed, let meta = tail.rolloutMeta(path: r.path) { r.cwd = meta.cwd; r.startedAt = meta.startedAt; r.parentID = meta.parentThreadID }
                out.append(r)
            }
        }
        return out
    }

    /// The rollout this process has open right now (exact), newest by mtime when it somehow holds several.
    func openRollout(pid: Int32) -> Rollout? {
        let root = realPath((config.codexDir as NSString).appendingPathComponent("sessions")) + "/"
        var best: Rollout?
        for p in source.openVnodePaths(pid) where p.hasPrefix(root) {
            let name = (p as NSString).lastPathComponent
            guard let (id, comp) = DiscoveryRegistry.rolloutID(fromFileName: name), let m = DiscoveryRegistry.mtime(p) else { continue }
            var r = Rollout(path: p, id: id, mtime: m, cwd: nil, startedAt: nil, compressed: comp)
            if !comp, let meta = tail.rolloutMeta(path: p) { r.cwd = meta.cwd; r.startedAt = meta.startedAt; r.parentID = meta.parentThreadID }
            if best == nil || r.mtime > best!.mtime { best = r }
        }
        return best
    }

    func bestRollout(for p: AgentProcess, in rollouts: [Rollout], claimed: Set<String>, siblings: Int) -> Rollout? {   // `claimed` holds rollout ids
        guard let cwd = p.cwd else { return nil }
        let pool = rollouts.filter { !claimed.contains($0.id) && $0.cwd == cwd && $0.mtime >= p.start.addingTimeInterval(-10) }
        if pool.isEmpty { return nil }
        if siblings > 1 {
            // Several sessions in one directory: pair by start time.
            return pool.filter { $0.startedAt != nil }.min { abs($0.startedAt!.timeIntervalSince(p.start)) < abs($1.startedAt!.timeIntervalSince(p.start)) }
        }
        return pool.max { $0.mtime < $1.mtime }
    }
}

extension ProcessScanner {
    /// Lazy variant of hostApp for a pid that was not classified as an agent (e.g. a registry pid).
    func hostApp(ofPid pid: Int32) -> (String?, Bool) {
        var basics: [Int32: ProcBasic] = [:]
        var cur = pid
        var hops = 0
        while cur > 1, hops <= 41, let b = source.basic(cur) { basics[cur] = b; if b.ppid == cur { break }; cur = b.ppid; hops += 1 }
        let r = hostApp(of: pid, basics: basics, path: { self.source.path($0) })
        return (r.bundleID, r.underTmux)
    }
}

// MARK: - Polling policy

/// Runs `scan` at start, then every `interval` seconds, backing off when nothing was found, and immediately on
/// `refreshNow()`. Costs nothing while stopped (no timer, no queue work).
final class DiscoveryLoop {
    let interval: TimeInterval
    let maxBackoff: TimeInterval
    /// While the Agents tab / notch indicator needs live data: one pass per this many seconds (default 5).
    let activeInterval: TimeInterval
    private let queue: DispatchQueue
    private let scan: () -> DiscoveryResult
    private let deliver: (DiscoveryResult) -> Void
    private var timer: DispatchSourceTimer?
    private var running = false
    private var active = false
    private var emptyScans = 0
    private var refreshQueued = false
    private var lastScan: DispatchTime?
    private let countLock = NSLock()
    private var _scanCount = 0
    /// Number of scans so far (readable from any thread).
    var scanCount: Int { countLock.lock(); defer { countLock.unlock() }; return _scanCount }

    init(interval: TimeInterval = 15, maxBackoff: TimeInterval = 60, activeInterval: TimeInterval = 5, qos: DispatchQoS = .utility,
         scan: @escaping () -> DiscoveryResult, deliver: @escaping (DiscoveryResult) -> Void) {
        self.interval = interval; self.maxBackoff = maxBackoff; self.activeInterval = activeInterval
        self.queue = DispatchQueue(label: "atoll.agents.discovery", qos: qos)
        self.scan = scan; self.deliver = deliver
    }

    /// 5 s while the UI needs it; otherwise 15 s while something is found, 2x after the first empty scan, `maxBackoff` (60 s) after.
    static func delay(interval: TimeInterval, maxBackoff: TimeInterval, emptyScans: Int, active: Bool = false, activeInterval: TimeInterval = 5) -> TimeInterval {
        if active { return activeInterval }
        if emptyScans <= 0 { return interval }
        if emptyScans == 1 { return min(maxBackoff, interval * 2) }
        return maxBackoff
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true; emptyScans = 0
            tick()
        }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel(); timer = nil
            refreshQueued = false
        }
    }

    /// The UI tells us whether it is looking (Agents tab open / indicator visible). Turning it on scans soon if the last
    /// scan is older than `activeInterval`; turning it off relaxes the cadence. Never faster than `activeInterval`.
    func setActive(_ on: Bool) {
        queue.async { [self] in
            guard active != on else { return }
            active = on
            guard running else { return }
            if on, let last = lastScan, Double(DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds) / 1e9 >= activeInterval { tick() }
            else { arm() }
        }
    }

    func refreshNow() {
        queue.async { [self] in
            guard running, !refreshQueued else { return }
            refreshQueued = true
            tick()
        }
    }

    private func tick() {
        guard running else { return }
        refreshQueued = false
        timer?.cancel(); timer = nil
        let result = scan()
        countLock.lock(); _scanCount += 1; countLock.unlock()
        lastScan = .now()
        emptyScans = result.sessions.isEmpty ? emptyScans + 1 : 0
        guard running else { return }
        deliver(result)
        arm()
    }

    private func arm() {
        timer?.cancel(); timer = nil
        guard running else { return }
        var delay = DiscoveryLoop.delay(interval: interval, maxBackoff: maxBackoff, emptyScans: emptyScans, active: active, activeInterval: activeInterval)
        if let last = lastScan {   // time already elapsed since the last scan counts
            delay = max(0.05, delay - Double(DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds) / 1e9)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(active ? 100 : 500))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }
}
