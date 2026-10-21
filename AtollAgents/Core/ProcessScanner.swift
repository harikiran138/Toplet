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

// libproc-based process scan (research 4.2). No `ps`/`lsof` spawns. Same-uid processes only for argv/cwd.

struct ProcBasic: Equatable {
    var pid: Int32
    var ppid: Int32
    var uid: uid_t
    var start: Date
    var ttyDevice: UInt32?       // nil = no controlling terminal
    var comm: String
}

/// Everything the scanner needs from the OS, injectable for tests.
protocol ProcessSource {
    func allPIDs() -> [Int32]
    func basic(_ pid: Int32) -> ProcBasic?
    func path(_ pid: Int32) -> String?
    func cwd(_ pid: Int32) -> String?
    func argv(_ pid: Int32) -> [String]?
    func ttyName(_ device: UInt32) -> String?
    /// Paths of the vnodes (regular files) the process has open (PROC_PIDLISTFDS + PROC_PIDFDVNODEPATHINFO).
    func openVnodePaths(_ pid: Int32) -> [String]
}

extension ProcessSource {
    func openVnodePaths(_ pid: Int32) -> [String] { [] }
}

struct LibprocSource: ProcessSource {
    init() {}

    func allPIDs() -> [Int32] {
        let need = proc_listallpids(nil, 0)
        guard need > 0 else { return [] }
        var buf = [Int32](repeating: 0, count: Int(need) + 128)
        let got = buf.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return buf.prefix(Int(got)).filter { $0 > 0 }
    }

    func basic(_ pid: Int32) -> ProcBasic? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let comm = withUnsafeBytes(of: &info.pbi_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        let tdev: UInt32? = (info.e_tdev == UInt32.max || info.e_tdev == 0) ? nil : info.e_tdev
        return ProcBasic(pid: Int32(info.pbi_pid), ppid: Int32(info.pbi_ppid), uid: info.pbi_uid, start: start, ttyDevice: tdev, comm: comm)
    }

    func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let s = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return s.isEmpty ? nil : s
    }

    /// argv via KERN_PROCARGS2 (same-uid processes only). Layout: int32 argc, exec path, NUL padding, argv[0..argc), env.
    func argv(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return nil }
        size = min(size, 1 << 20)
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 8 else { return nil }
        let argc = Int(buf[0]) | Int(buf[1]) << 8 | Int(buf[2]) << 16 | Int(buf[3]) << 24
        guard argc > 0, argc < 4096 else { return nil }
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }          // exec path
        while i < size, buf[i] == 0 { i += 1 }          // padding
        var out: [String] = []
        while i < size, out.count < argc {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            out.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out
    }

    /// Idea (MIT, credit): realfishsam/agent-notch maps Codex sessions to their rollout via the process's open files.
    /// Our own implementation with libproc, no lsof.
    func openVnodePaths(_ pid: Int32) -> [String] {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var out: [String] = []
        for i in 0..<min(Int(got) / stride, 4096) where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let p = withUnsafeBytes(of: &info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if !p.isEmpty { out.append(p) }
        }
        return out
    }

    func ttyName(_ device: UInt32) -> String? {
        var buf = [CChar](repeating: 0, count: 64)
        guard devname_r(dev_t(device), S_IFCHR, &buf, Int32(buf.count)) != nil else { return nil }
        let s = String(cString: buf)
        return s.isEmpty || s == "??" ? nil : "/dev/" + s
    }
}

/// pid -> hosting app bundle id (Terminal, iTerm2, VS Code ...). Implementations must be cheap and thread-safe.
protocol AppResolver {
    func bundleID(forPid pid: Int32, executablePath: String?) -> String?
}

/// Reads CFBundleIdentifier from the outermost `.app` containing the executable. AppKit-free, deterministic, testable.
final class PlistAppResolver: AppResolver {
    private var cache: [String: String?] = [:]
    private let lock = NSLock()
    init() {}

    func bundleID(forPid pid: Int32, executablePath: String?) -> String? {
        guard let p = executablePath, let r = p.range(of: ".app/") else { return nil }
        let app = String(p[p.startIndex..<r.upperBound].dropLast())          // ".../Foo.app"
        lock.lock(); defer { lock.unlock() }
        if let c = cache[app] { return c }
        var id: String?
        let plist = app + "/Contents/Info.plist"
        if let d = FileManager.default.contents(atPath: plist),
           let o = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any] {
            id = o["CFBundleIdentifier"] as? String
        }
        cache[app] = id
        return id
    }
}

/// realpath(3). NSString.resolvingSymlinksInPath would turn /private/tmp into /tmp, but the kernel reports /private/tmp.
func realPath(_ path: String) -> String {
    guard let r = realpath(path, nil) else { return path }
    defer { free(r) }
    return String(cString: r)
}

// MARK: - Classification

struct AgentProcessMatch: Equatable {
    var kind: AgentKind
    /// A launcher (node script) whose child is the real binary; dropped when that child is also found.
    var isWrapper: Bool
}

enum ProcessClassifier {
    static let claudeSubcommands: Set<String> = ["mcp", "doctor", "update", "install", "config", "agents", "logs", "attach", "stop", "rm",
                                                 "respawn", "daemon", "plugin", "plugins", "migrate-installer", "setup-token", "api-key", "--version", "-v"]
    static let codexSubcommands: Set<String> = ["app-server", "mcp-server", "mcp", "exec", "e", "exec-server", "proxy", "login", "logout", "completion",
                                                "sandbox", "debug", "apply", "cloud", "features", "agents", "review", "daemon", "remote", "app",
                                                "code-mode-host", "responses-api-proxy", "--version", "-V"]
    /// Codex options that consume the next argument (so it is not mistaken for a subcommand: `-c key="value" exec-server`).
    static let codexValueOptions: Set<String> = ["-c", "--config", "-m", "--model", "-p", "--profile", "-C", "--cd", "-i", "--image", "-s", "--sandbox",
                                                 "-a", "--ask-for-approval", "--oss-provider", "--local-provider", "--add-dir"]

    /// First operand of a Codex command line, skipping options and their values.
    static func codexOperand(_ args: [String]) -> String? {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" { return i + 1 < args.count ? args[i + 1] : nil }
            if a.hasPrefix("-") { i += codexValueOptions.contains(a) ? 2 : 1; continue }
            return a
        }
        return nil
    }

    /// `codex-aarch64-apple-darwin` (the vendored native binary), not helpers such as `codex-code-mode-host`.
    static func isVendoredCodexName(_ lower: String) -> Bool {
        lower.hasPrefix("codex-") && lower.contains("-apple-darwin")
    }

    /// Cheap pre-filter on executable path / comm: is this process worth reading argv for?
    static func isCandidate(path: String?, comm: String) -> Bool {
        let base = ((path ?? "") as NSString).lastPathComponent
        let lower = base.lowercased()
        if lower == "claude" || lower == "codex" || isVendoredCodexName(lower) || lower == "node" { return true }
        if let p = path, p.contains("/.local/share/claude/versions/") || p.contains("/Caskroom/claude-code") || p.contains("@anthropic-ai/claude-code") || p.contains("@openai/codex") { return true }
        // Native Claude binaries can be named after their version ("2.1.299").
        if comm.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil { return true }
        return false
    }

    static func classify(path: String?, comm: String, argv: [String]?) -> AgentProcessMatch? {
        let exe = path ?? ""
        let base = (exe as NSString).lastPathComponent
        let lower = base.lowercased()
        let args = Array((argv ?? []).dropFirst())
        let inApp = exe.contains(".app/Contents/")

        func firstOperand() -> String? { args.first(where: { !$0.hasPrefix("-") }) }
        func hasFlag(_ flags: Set<String>) -> Bool {
            for a in args { if a == "--" { return false }; if flags.contains(a) { return true } }
            return false
        }

        // --- Claude ---
        let claudeishPath = exe.contains("/.local/share/claude/versions/") || exe.contains("/Caskroom/claude-code")
            || exe.contains("@anthropic-ai/claude-code") || exe.contains("/claude-code/")
        if base == "claude" || claudeishPath
            || (comm.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil && exe.contains("claude")) {
            // GUI helpers: Electron main/helper binaries live in an .app and are not named "claude".
            if inApp && base != "claude" { return nil }
            if hasFlag(["-p", "--print"]) { return nil }
            if args.contains("stream-json") { return nil }
            if let op = firstOperand(), claudeSubcommands.contains(op), args.first == op { return nil }
            return AgentProcessMatch(kind: .claudeCode, isWrapper: false)
        }
        if lower == "node" {
            // Older npm installs: node .../@anthropic-ai/claude-code/cli.js  /  node .../@openai/codex/bin/codex.js
            let script = args.first(where: { !$0.hasPrefix("-") }) ?? ""
            if script.contains("@anthropic-ai/claude-code") {
                if hasFlag(["-p", "--print"]) || args.contains("stream-json") { return nil }
                if let op = args.drop(while: { $0 != script }).dropFirst().first(where: { !$0.hasPrefix("-") }), claudeSubcommands.contains(op) { return nil }
                return AgentProcessMatch(kind: .claudeCode, isWrapper: false)
            }
            if script.contains("@openai/codex") || script.hasSuffix("/codex") || script.hasSuffix("/codex.js") {
                let rest = Array(args.drop(while: { $0 != script }).dropFirst())
                if let op = codexOperand(rest), codexSubcommands.contains(op) { return nil }
                if rest.contains("--managed-daemon") { return nil }
                return AgentProcessMatch(kind: .codex, isWrapper: true)
            }
            return nil
        }

        // --- Codex ---
        if lower == "codex" || isVendoredCodexName(lower) || exe.contains("@openai/codex") {
            if args.contains("--managed-daemon") || args.contains("app-server") { return nil }
            if let op = codexOperand(args), codexSubcommands.contains(op) { return nil }
            if hasFlag(["--listen"]) { return nil }
            return AgentProcessMatch(kind: .codex, isWrapper: false)
        }
        return nil
    }
}

// MARK: - Scan

struct AgentProcess: Equatable {
    var kind: AgentKind
    var pid: Int32
    var ppid: Int32
    var start: Date
    var tty: String?
    var cwd: String?
    var exe: String?
    var argv: [String]
    var hostBundleID: String?
    var underTmux: Bool
}

struct ProcessScan {
    var agents: [AgentProcess]
    var processCount: Int
    /// pid -> (ppid, start) for every process seen (used for liveness and ancestry in tests/diagnostics).
    var parents: [Int32: Int32]
}

final class ProcessScanner {
    let source: ProcessSource
    let uid: uid_t
    let apps: AppResolver

    init(source: ProcessSource = LibprocSource(), uid: uid_t = getuid(), apps: AppResolver = PlistAppResolver()) {
        self.source = source; self.uid = uid; self.apps = apps
    }

    func scan() -> ProcessScan {
        let pids = source.allPIDs()
        var basics: [Int32: ProcBasic] = [:]
        basics.reserveCapacity(pids.count)
        for pid in pids { if let b = source.basic(pid) { basics[pid] = b } }

        var pathCache: [Int32: String?] = [:]
        func path(_ pid: Int32) -> String? {
            if let c = pathCache[pid] { return c }
            let p = source.path(pid); pathCache[pid] = p; return p
        }

        struct Cand { var proc: ProcBasic; var exe: String?; var argv: [String]; var match: AgentProcessMatch }
        var cands: [Int32: Cand] = [:]
        for (pid, b) in basics where b.uid == uid {
            let exe = path(pid)
            guard ProcessClassifier.isCandidate(path: exe, comm: b.comm) else { continue }
            let argv = source.argv(pid) ?? []
            guard let m = ProcessClassifier.classify(path: exe, comm: b.comm, argv: argv) else { continue }
            cands[pid] = Cand(proc: b, exe: exe, argv: argv, match: m)
        }

        // Drop same-kind child forks of a real (non-wrapper) agent, and wrappers that have an agent child.
        var kept: [Cand] = []
        for (pid, c) in cands {
            if let parent = cands[c.proc.ppid], parent.match.kind == c.match.kind, !parent.match.isWrapper, !c.match.isWrapper { continue }
            if c.match.isWrapper, cands.values.contains(where: { $0.proc.ppid == pid && $0.match.kind == c.match.kind }) { continue }
            kept.append(c)
        }

        var agents: [AgentProcess] = []
        for c in kept.sorted(by: { $0.proc.pid < $1.proc.pid }) {
            let (host, tmux) = hostApp(of: c.proc.pid, basics: basics, path: path)
            let tty = c.proc.ttyDevice.flatMap { source.ttyName($0) }
            agents.append(AgentProcess(kind: c.match.kind, pid: c.proc.pid, ppid: c.proc.ppid, start: c.proc.start, tty: tty,
                                       cwd: source.cwd(c.proc.pid), exe: c.exe, argv: c.argv, hostBundleID: host, underTmux: tmux))
        }
        return ProcessScan(agents: agents, processCount: basics.count, parents: basics.mapValues { $0.ppid })
    }

    /// Walks ppid (<= 40 hops) to the first GUI app. Also reports whether a tmux process is an ancestor.
    func hostApp(of pid: Int32, basics: [Int32: ProcBasic], path: (Int32) -> String?) -> (bundleID: String?, underTmux: Bool) {
        var cur = basics[pid]?.ppid ?? 0
        var hops = 0
        var tmux = false
        while cur > 1, hops < 40 {
            hops += 1
            let p = path(cur)
            if let p = p, (p as NSString).lastPathComponent == "tmux" || (p as NSString).lastPathComponent.hasPrefix("tmux") { tmux = true }
            if let id = apps.bundleID(forPid: cur, executablePath: p) { return (id, tmux) }
            guard let next = basics[cur]?.ppid, next != cur else { break }
            cur = next
        }
        return (nil, tmux)
    }
}

// MARK: - Liveness

enum ProcessLiveness {
    /// True when `pid` exists and, if `expectedStart` is given, started within `tolerance` seconds of it (PID-reuse guard).
    static func isAlive(pid: Int32, expectedStart: Date?, source: ProcessSource = LibprocSource(), tolerance: TimeInterval = 5) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno != EPERM { return false }
        if let exp = expectedStart, let b = source.basic(pid) {
            if abs(b.start.timeIntervalSince(exp)) > tolerance { return false }
            // A zombie still answers kill(0); libproc reports its status as SZOMB.
        }
        return true
    }
}
