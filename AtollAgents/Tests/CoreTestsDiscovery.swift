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

// MARK: Fakes

final class FakeProcs: ProcessSource {
    struct P { var basic: ProcBasic; var path: String?; var cwd: String?; var argv: [String]? }
    private var _procs: [Int32: P] = [:]
    private let lock = NSLock()
    private var _listCalls = 0
    private var _fds: [Int32: [String]] = [:]
    func setFDs(_ pid: Int32, _ paths: [String]) { lock.withLock { _fds[pid] = paths } }
    func openVnodePaths(_ pid: Int32) -> [String] { lock.withLock { _fds[pid] ?? [] } }
    var procs: [Int32: P] { get { lock.withLock { _procs } } set { lock.withLock { _procs = newValue } } }
    var listCalls: Int { lock.withLock { _listCalls } }
    func remove(_ pid: Int32) { lock.withLock { _ = _procs.removeValue(forKey: pid) } }

    func add(_ pid: Int32, ppid: Int32 = 1, uid: uid_t = getuid(), tty: UInt32? = nil, start: Date = Date().addingTimeInterval(-3600),
             comm: String = "x", path: String?, cwd: String? = nil, argv: [String]? = nil) {
        let p = P(basic: ProcBasic(pid: pid, ppid: ppid, uid: uid, start: start, ttyDevice: tty, comm: comm), path: path, cwd: cwd, argv: argv ?? [((path ?? "x") as NSString).lastPathComponent])
        lock.withLock { _procs[pid] = p }
    }
    func allPIDs() -> [Int32] { lock.withLock { _listCalls += 1; return Array(_procs.keys).sorted() } }
    func basic(_ pid: Int32) -> ProcBasic? { lock.withLock { _procs[pid]?.basic } }
    func path(_ pid: Int32) -> String? { lock.withLock { _procs[pid]?.path } }
    func cwd(_ pid: Int32) -> String? { lock.withLock { _procs[pid]?.cwd } }
    func argv(_ pid: Int32) -> [String]? { lock.withLock { _procs[pid]?.argv } }
    func ttyName(_ device: UInt32) -> String? { "/dev/ttys\(String(format: "%03d", device))" }
}

/// Creates `<root>/<name>.app` with an Info.plist and returns the main executable path.
func makeFakeApp(_ root: String, _ name: String, bundleID: String, exe: String? = nil) -> String {
    let exeName = exe ?? name
    let dir = "\(root)/\(name).app/Contents"
    try? FileManager.default.createDirectory(atPath: dir + "/MacOS", withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
    if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) { FileManager.default.createFile(atPath: dir + "/Info.plist", contents: d) }
    return "\(dir)/MacOS/\(exeName)"
}

func registryJSON(pid: Int, sid: String, cwd: String, startedAt: Date, status: String? = "busy", extra: [String: Any] = [:]) -> String {
    var o: [String: Any] = ["pid": pid, "sessionId": sid, "cwd": cwd, "startedAt": Int(startedAt.timeIntervalSince1970 * 1000), "procStart": "Wed Oct 21 04:25:06 2026",
                            "version": "2.1.299", "kind": "interactive", "entrypoint": "cli", "pidDomain": "darwin", "peerProtocol": 1, "peerFeatures": [], "name": "Session name"]
    if let s = status { o["status"] = s; o["statusUpdatedAt"] = Int(Date().timeIntervalSince1970 * 1000) }
    for (k, v) in extra { o[k] = v }
    return jsonString(o)
}

func claudeSlug(_ cwd: String) -> String { DiscoveryRegistry.slug(cwd) }

func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d) }

func setMTime(_ path: String, _ date: Date) {
    var times = [timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)]
    utimes(path, &times)
}


func runDiscoveryTests() async {
    section("Process classification (research 4.2)")
    let home = "/Users/me"
    func cl(_ path: String?, _ argv: [String], comm: String = "x") -> AgentProcessMatch? { ProcessClassifier.classify(path: path, comm: comm, argv: argv) }
    let claudeBin = "\(home)/.local/share/claude/versions/2.1.299"
    check(cl(claudeBin, ["claude"], comm: "2.1.299")?.kind == .claudeCode, "claude: native binary under ~/.local/share/claude/versions")
    check(cl(claudeBin, ["claude", "--resume", "abc"], comm: "2.1.299")?.kind == .claudeCode, "claude: interactive with --resume")
    check(cl(claudeBin, ["claude", "-p", "summarise this"]) == nil, "claude -p (headless) excluded")
    check(cl(claudeBin, ["claude", "--print", "x"]) == nil, "claude --print excluded")
    check(cl(claudeBin, ["claude", "--output-format", "stream-json", "--input-format", "stream-json"]) == nil, "claude stream-json excluded")
    check(cl(claudeBin, ["claude", "mcp", "serve"]) == nil, "claude mcp excluded")
    check(cl(claudeBin, ["claude", "agents", "--json"]) == nil, "claude agents excluded")
    check(cl(claudeBin, ["claude", "attach", "abc"]) == nil, "claude attach excluded")
    check(cl("/opt/homebrew/Caskroom/claude-code/2.1.299/claude", ["claude"])?.kind == .claudeCode, "claude: Homebrew Caskroom")
    check(cl("/x/node_modules/@anthropic-ai/claude-code-darwin-arm64/claude", ["claude"])?.kind == .claudeCode, "claude: npm native package")
    check(cl("/usr/local/bin/node", ["node", "/x/node_modules/@anthropic-ai/claude-code/cli.js"])?.kind == .claudeCode, "claude: node + cli.js")
    check(cl("/usr/local/bin/node", ["node", "/x/node_modules/@anthropic-ai/claude-code/cli.js", "-p", "hi"]) == nil, "claude: node cli.js -p excluded")
    check(cl("/Applications/Claude.app/Contents/MacOS/Claude", ["Claude"]) == nil, "Electron GUI main binary excluded")
    check(cl("/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)", ["h"]) == nil, "Electron GUI helper excluded")
    check(cl("/Users/me/Library/Application Support/Claude/claude-code/2.1.299/claude.app/Contents/MacOS/claude", ["claude"])?.kind == .claudeCode, "claude binary embedded in an .app is accepted")
    check(cl("/opt/homebrew/bin/codex", ["codex"])?.kind == .codex, "codex: native binary")
    check(cl("/opt/homebrew/bin/codex", ["codex", "resume"])?.kind == .codex, "codex resume is an interactive session")
    check(cl("/opt/homebrew/bin/codex", ["codex", "app-server", "--listen", "unix://"]) == nil, "codex app-server excluded")
    check(cl("/opt/homebrew/bin/codex", ["codex", "--managed-daemon"]) == nil, "codex managed daemon excluded")
    check(cl("/opt/homebrew/bin/codex", ["codex", "exec", "do it"]) == nil, "codex exec (headless) excluded")
    check(cl("/opt/homebrew/bin/codex", ["codex", "mcp-server"]) == nil, "codex mcp-server excluded")
    // Observed on a real Mac with the ChatGPT/Codex desktop app installed (not sessions, must not be listed):
    check(cl("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex-code-mode-host", ["codex-code-mode-host"]) == nil, "codex-code-mode-host helper is not a session")
    check(cl("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", ["codex", "-c", "forced_login_method=\"chatgpt\"", "exec-server", "--remote", "https://x/api", "--environment-id", "abc"]) == nil, "codex -c key=value exec-server is not a session")
    check(cl("/opt/homebrew/bin/codex", ["codex", "-c", "model=\"o3\"", "-m", "gpt-5", "fix the failing test"])?.kind == .codex, "codex with options and a prompt is an interactive session")
    check(cl("/opt/homebrew/bin/codex", ["codex", "-c", "a=b", "resume", "--last"])?.kind == .codex, "codex -c a=b resume is an interactive session")
    check(cl("/opt/homebrew/bin/codex", ["codex", "-c", "a=b", "exec", "run it"]) == nil, "codex -c a=b exec is headless")
    check(cl("/opt/homebrew/bin/codex", ["codex", "--model", "exec"])?.kind == .codex, "an option VALUE that looks like a subcommand is not a subcommand")
    check(ProcessClassifier.codexOperand(["-c", "x=y", "--", "exec"]) == "exec", "codexOperand: after -- everything is an operand")
    check(cl("/x/vendor/codex-x86_64-apple-darwin", ["codex"])?.kind == .codex, "codex: x86_64 vendored binary name")
    check(cl("/x/vendor/codex-aarch64-apple-darwin", ["codex"])?.kind == .codex, "codex: vendored native binary name")
    let wrapper = cl("/usr/local/bin/node", ["node", "/x/lib/node_modules/@openai/codex/bin/codex.js"])
    check(wrapper?.kind == .codex && wrapper?.isWrapper == true, "codex: node wrapper is flagged as a wrapper")
    check(cl("/usr/local/bin/node", ["node", "/x/lib/node_modules/@openai/codex/bin/codex.js", "app-server"]) == nil, "codex wrapper running app-server excluded")
    check(cl("/usr/local/bin/node", ["node", "server.js"]) == nil, "unrelated node process ignored")
    check(cl("/bin/zsh", ["-zsh"]) == nil, "shell ignored")
    check(cl(nil, []) == nil, "no path, no argv: ignored")
    check(ProcessClassifier.isCandidate(path: "/bin/zsh", comm: "zsh") == false, "pre-filter skips shells")
    check(ProcessClassifier.isCandidate(path: claudeBin, comm: "2.1.299"), "pre-filter accepts the versioned binary")

    section("Process scanner (fake process table)")
    do {
        let apps = makeTmp("apps")
        let termExe = makeFakeApp(apps, "Terminal", bundleID: "com.apple.Terminal")
        let codeExe = makeFakeApp(apps, "Visual Studio Code", bundleID: "com.microsoft.VSCode")
        let codeHelper = "\(apps)/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        let f = FakeProcs()
        f.add(10, ppid: 1, path: termExe)
        f.add(11, ppid: 10, path: "/bin/zsh")
        f.add(12, ppid: 11, tty: 4, path: claudeBin, cwd: "/work/a", argv: ["claude"])
        f.add(20, ppid: 1, path: codeExe)
        f.add(21, ppid: 20, path: codeHelper)
        f.add(22, ppid: 21, path: "/bin/zsh")
        f.add(23, ppid: 22, tty: 5, path: claudeBin, cwd: "/work/b", argv: ["claude"])
        f.add(30, ppid: 1, path: "/opt/homebrew/bin/tmux")
        f.add(31, ppid: 30, path: "/bin/zsh")
        f.add(32, ppid: 31, tty: 6, path: "/opt/homebrew/bin/codex", cwd: "/work/c", argv: ["codex"])
        f.add(40, ppid: 12, path: claudeBin, cwd: "/work/a", argv: ["claude"])                     // same-kind child fork of 12
        f.add(41, ppid: 11, path: "/usr/local/bin/node", cwd: "/work/d", argv: ["node", "/x/@openai/codex/bin/codex.js"])   // wrapper ...
        f.add(42, ppid: 41, tty: 7, path: "/x/vendor/codex", cwd: "/work/d", argv: ["codex"])      // ... with a native child
        f.add(43, ppid: 11, path: "/usr/local/bin/node", cwd: "/work/e", argv: ["node", "/x/@openai/codex/bin/codex.js"])   // lone wrapper
        f.add(50, ppid: 11, uid: 0, path: claudeBin, cwd: "/work/root", argv: ["claude"])           // someone else's process
        f.add(51, ppid: 11, path: claudeBin, cwd: "/work/p", argv: ["claude", "-p", "x"])           // headless
        f.add(52, ppid: 11, path: "/opt/homebrew/bin/codex", cwd: "/work/s", argv: ["codex", "app-server"])
        let scan = ProcessScanner(source: f, uid: getuid(), apps: PlistAppResolver()).scan()
        let byPid = Dictionary(uniqueKeysWithValues: scan.agents.map { ($0.pid, $0) })
        eq(Set(byPid.keys), Set([12, 23, 32, 42, 43]), "scanner keeps real sessions, drops forks, wrapper-with-child, foreign uid, headless and app-server")
        eq(byPid[12]?.hostBundleID ?? "nil", "com.apple.Terminal", "pid -> hosting app via ppid walk (Terminal)")
        eq(byPid[23]?.hostBundleID ?? "nil", "com.microsoft.VSCode", "nested helper .app resolves to the outermost app (VS Code)")
        eq(byPid[12]?.tty ?? "nil", "/dev/ttys004", "tty from the controlling terminal device")
        eq(byPid[12]?.cwd ?? "nil", "/work/a", "cwd carried")
        check(byPid[32]?.underTmux == true, "tmux ancestor is detected")
        check(byPid[32]?.hostBundleID == nil, "tmux-hosted session has no GUI host by ppid")
        check(byPid[12]?.underTmux == false, "non-tmux session is not flagged")
        eq(byPid[43]?.kind ?? .claudeCode, .codex, "a lone wrapper is kept")
        // 40-hop limit
        let g = FakeProcs()
        g.add(100, ppid: 1, path: termExe)
        for i in 101...150 { g.add(Int32(i), ppid: Int32(i - 1), path: "/bin/zsh") }
        g.add(151, ppid: 150, path: claudeBin, cwd: "/w", argv: ["claude"])
        let scan2 = ProcessScanner(source: g, uid: getuid(), apps: PlistAppResolver()).scan()
        check(scan2.agents.first?.hostBundleID == nil, "ppid walk stops after 40 hops")
        g.add(200, ppid: 1, path: termExe)
        for i in 201...230 { g.add(Int32(i), ppid: Int32(i - 1), path: "/bin/zsh") }
        g.add(231, ppid: 230, path: claudeBin, cwd: "/w2", argv: ["claude"])
        let scan3 = ProcessScanner(source: g, uid: getuid(), apps: PlistAppResolver()).scan()
        eq(scan3.agents.first(where: { $0.pid == 231 })?.hostBundleID ?? "nil", "com.apple.Terminal", "a 31-hop chain still resolves")
        // a ppid cycle must not loop forever
        let cyc = FakeProcs()
        cyc.add(300, ppid: 301, path: "/bin/zsh"); cyc.add(301, ppid: 300, path: "/bin/zsh"); cyc.add(302, ppid: 300, path: claudeBin, cwd: "/w", argv: ["claude"])
        check(ProcessScanner(source: cyc, uid: getuid(), apps: PlistAppResolver()).scan().agents.count == 1, "a ppid cycle terminates")
        eq(PlistAppResolver().bundleID(forPid: 1, executablePath: "/nope/Nothing.app/Contents/MacOS/x") ?? "nil", "nil", "missing bundle plist gives nil")
        eq(PlistAppResolver().bundleID(forPid: 1, executablePath: "/bin/zsh") ?? "nil", "nil", "non-app executable gives nil")
    }

    section("Registry reading (fake ~/.claude)")
    eq(HostApps.surface(entrypoint: "claude-desktop", kind: "interactive") ?? .unknown, .desktopApp, "entrypoint claude-desktop -> desktopApp")
    eq(HostApps.surface(entrypoint: "claude-vscode", kind: nil) ?? .unknown, .vscode, "entrypoint claude-vscode -> vscode")
    eq(HostApps.surface(entrypoint: "cli", kind: "background") ?? .unknown, .background, "kind background -> background")
    eq(HostApps.surface(entrypoint: "sdk-cli", kind: nil) ?? .unknown, .headless, "entrypoint sdk -> headless")
    // real-shaped entry
    let now = Date()
    let started = now.addingTimeInterval(-3000)
    let e1 = DiscoveryRegistry.parseRegistryEntry(Data(registryJSON(pid: 4001, sid: "aaaa-1111", cwd: "/work/a", startedAt: started).utf8))
    eq(e1?.pid ?? 0, 4001, "registry entry: pid"); eq(e1?.sessionID ?? "", "aaaa-1111", "registry entry: sessionId"); eq(e1?.status ?? "", "busy", "registry entry: status")
    eq(e1?.name ?? "", "Session name", "registry entry: name"); check(abs((e1?.startedAt?.timeIntervalSince(started) ?? 99)) < 1, "registry entry: startedAt (ms)")
    check(DiscoveryRegistry.parseRegistryEntry(Data("{\"sessionId\":\"x\",\"cwd\":\"/\"}".utf8)) == nil, "registry entry without pid rejected")
    check(DiscoveryRegistry.parseRegistryEntry(Data("{\"pid\":5,\"cwd\":\"/\"}".utf8)) == nil, "registry entry without sessionId rejected")
    check(DiscoveryRegistry.parseRegistryEntry(Data("{\"pid\":5,\"sessionId\":\"../../etc/passwd\",\"cwd\":\"/\"}".utf8)) == nil, "registry entry with a path-traversal session id rejected")
    check(DiscoveryRegistry.parseRegistryEntry(Data("{\"pid\":1,\"sessionId\":\"x\"}".utf8)) == nil, "registry entry with pid 1 rejected")
    check(!DiscoveryRegistry.isSafeID("abc\n") && !DiscoveryRegistry.isSafeID("a/b") && !DiscoveryRegistry.isSafeID("") && !DiscoveryRegistry.isSafeID(".hidden") && DiscoveryRegistry.isSafeID("0198aaaa-bbbb-7ccc-8ddd-eeeeffff0000"), "isSafeID: no newline, slash, empty or leading dot")
    check(DiscoveryRegistry.parseRegistryEntry(Data("[1,2]".utf8)) == nil, "registry file that is not an object rejected")
    check(DiscoveryRegistry.parseRegistryEntry(Data("{\"pid\":\"77\",\"sessionId\":\"s-1\",\"cwd\":\"/x\",\"startedAt\":1792388523}".utf8))?.pid == 77, "registry entry with a numeric-string pid and startedAt in seconds")
    eq(DiscoveryRegistry.mapStatus("busy", waitingFor: nil)?.0 ?? .unknown, .running, "status busy -> running")
    eq(DiscoveryRegistry.mapStatus("idle", waitingFor: nil)?.0 ?? .unknown, .idle, "status idle -> idle")
    eq(DiscoveryRegistry.mapStatus("waiting", waitingFor: "permission prompt")?.0 ?? .unknown, .needsPermission, "status waiting + permission prompt -> needsPermission")
    eq(DiscoveryRegistry.mapStatus("waiting", waitingFor: "input needed")?.0 ?? .unknown, .waitingInput, "status waiting + input -> waitingInput")
    eq(DiscoveryRegistry.mapStatus("waiting", waitingFor: nil)?.0 ?? .unknown, .waitingInput, "status waiting alone -> waitingInput")
    check(DiscoveryRegistry.mapStatus("mystery", waitingFor: nil) == nil, "unknown status ignored")
    check(DiscoveryRegistry.mapStatus(nil, waitingFor: nil) == nil, "missing status ignored")
    eq(DiscoveryRegistry.slug("/Users/dev/proj.x_y z"), "-Users-dev-proj-x-y-z", "transcript slug: non-alphanumerics become dashes")
    eq(DiscoveryRegistry.rolloutID(fromFileName: "rollout-2026-10-21T09-00-00-0198aaaa-bbbb-7ccc-8ddd-eeeeffff0000.jsonl")?.id ?? "nil", "0198aaaa-bbbb-7ccc-8ddd-eeeeffff0000", "rollout id from file name")
    check(DiscoveryRegistry.rolloutID(fromFileName: "rollout-2026-10-21T09-00-00-0198aaaa-bbbb-7ccc-8ddd-eeeeffff0000.jsonl.zst")?.compressed == true, "rollout .zst detected from file name")
    check(DiscoveryRegistry.rolloutID(fromFileName: "notes.txt") == nil, "non-rollout file name ignored")

    // Full scan against a fake ~/.claude with a fake process table
    do {
        let base = makeTmp("cl")
        let claudeDir = base + "/claude", codexDir = base + "/codex"
        let apps = makeTmp("apps")
        let termExe = makeFakeApp(apps, "Terminal", bundleID: "com.apple.Terminal")
        let desktopExe = makeFakeApp(apps, "Claude", bundleID: "com.anthropic.claudefordesktop")
        let procs = FakeProcs()
        procs.add(10, path: termExe)
        procs.add(11, ppid: 10, path: "/bin/zsh")
        procs.add(4001, ppid: 11, tty: 4, start: started, path: claudeBin, cwd: "/work/a", argv: ["claude"])          // live, registry says busy
        procs.add(4002, ppid: 11, tty: 5, start: started, path: claudeBin, cwd: "/work/b", argv: ["claude"])          // live, waiting for permission
        procs.add(4004, ppid: 11, start: now.addingTimeInterval(-60), path: "/bin/zsh", cwd: "/z")                      // pid reused by something started later
        procs.add(4005, ppid: 11, uid: 0, start: started, path: claudeBin, cwd: "/root", argv: ["claude"])            // foreign uid
        procs.add(20, path: desktopExe)
        procs.add(4006, ppid: 20, start: started, path: claudeBin, cwd: "/work/desk", argv: ["claude"])
        write(claudeDir + "/sessions/4001.json", registryJSON(pid: 4001, sid: "sess-a", cwd: "/work/a", startedAt: started, status: "busy"))
        write(claudeDir + "/sessions/4002.json", registryJSON(pid: 4002, sid: "sess-b", cwd: "/work/b", startedAt: started, status: "waiting", extra: ["waitingFor": "permission prompt"]))
        write(claudeDir + "/sessions/4003.json", registryJSON(pid: 4003, sid: "sess-dead", cwd: "/work/dead", startedAt: started))      // no such process
        write(claudeDir + "/sessions/4004.json", registryJSON(pid: 4004, sid: "sess-reuse", cwd: "/work/reuse", startedAt: started))     // pid reuse
        write(claudeDir + "/sessions/4005.json", registryJSON(pid: 4005, sid: "sess-root", cwd: "/root", startedAt: started))
        write(claudeDir + "/sessions/4006.json", registryJSON(pid: 4006, sid: "sess-desk", cwd: "/work/desk", startedAt: started, status: "idle", extra: ["entrypoint": "claude-desktop"]))
        write(claudeDir + "/sessions/junk.json", "{{{ not json")
        write(claudeDir + "/sessions/readme.txt", "ignore me")
        write(claudeDir + "/sessions/4001.abcdef.key", "secret-ish")
        write(claudeDir + "/sessions/huge.json", String(repeating: "x", count: 200_000))
        write(claudeDir + "/sessions/evil.json", registryJSON(pid: 4001, sid: "../../evil", cwd: "/x", startedAt: started))
        try? FileManager.default.createDirectory(atPath: claudeDir + "/sessions/subdir.json", withIntermediateDirectories: true)
        // transcript for sess-a
        let tpath = claudeDir + "/projects/\(claudeSlug("/work/a"))/sess-a.jsonl"
        write(tpath, [
            jsonString(["type": "user", "timestamp": iso(now.addingTimeInterval(-30)), "cwd": "/work/a", "message": ["role": "user", "content": "please fix the flaky test"]]),
            jsonString(["type": "ai-title", "aiTitle": "Fix flaky test"]),
            jsonString(["type": "assistant", "timestamp": iso(now.addingTimeInterval(-20)), "message": ["model": "claude-opus-4-7", "stop_reason": "tool_use", "content": [["type": "text", "text": "Running the test"], ["type": "tool_use", "id": "tu1", "name": "Bash", "input": ["command": "npm test"]]]]]),
        ].joined(separator: "\n") + "\n")
        let reg = DiscoveryRegistry(config: DiscoveryConfig(claudeDir: claudeDir, codexDir: codexDir), source: procs, apps: PlistAppResolver())
        let res = reg.scan()
        let byID = Dictionary(uniqueKeysWithValues: res.sessions.map { ($0.key.id, $0) })
        check(res.complete, "scan is complete when the process table was readable")
        eq(Set(byID.keys), Set(["sess-a", "sess-b", "sess-desk"]), "stale (dead pid), pid-reuse, foreign-uid, junk, oversized and unsafe registry files are ignored")
        let a = byID["sess-a"]!
        eq(a.pid ?? 0, 4001, "sess-a: pid"); eq(a.status ?? .unknown, .running, "sess-a: registry status busy -> running"); eq(a.statusProvenance, .registry, "sess-a: status provenance is registry")
        eq(a.title ?? "", "please fix the flaky test", "sess-a: title is the user's latest prompt"); eq(a.model ?? "", "claude-opus-4-7", "sess-a: model from the transcript tail"); eq(a.lastPrompt ?? "", "please fix the flaky test", "sess-a: last prompt from the transcript")
        eq(a.name ?? "", "Session name", "sess-a: registry name"); eq(a.tty ?? "", "/dev/ttys004", "sess-a: tty")
        eq(a.hostAppBundleID ?? "", "com.apple.Terminal", "sess-a: host app"); eq(a.surface ?? .unknown, .terminal, "sess-a: surface")
        eq(a.jump ?? .app(bundleID: "none"), .terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys004"), "sess-a: jump target is terminal+tty")
        eq(a.provenance, .registry, "sess-a: provenance"); eq(a.cwd, "/work/a", "sess-a: cwd"); eq(a.model ?? "", "claude-opus-4-7", "sess-a: model from the transcript")
        eq(a.transcriptPath ?? "", tpath, "sess-a: transcript path")
        eq(byID["sess-b"]!.status ?? .unknown, .needsPermission, "sess-b: waiting + permission prompt -> needsPermission")
        let d = byID["sess-desk"]!
        eq(d.surface ?? .unknown, .desktopApp, "sess-desk: entrypoint claude-desktop -> desktop app")
        eq(d.jump ?? .terminal(bundleID: "", tty: nil), .app(bundleID: "com.anthropic.claudefordesktop"), "sess-desk: jump just activates the desktop app")
        // reducer integration
        var st = ReducerState()
        SessionReducer.apply(discovered: res.sessions, complete: res.complete, to: &st, now: now)
        eq(st.sessions.count, 3, "reducer takes the discovered sessions")
        eq(SessionReducer.sorted(st).first?.key.id ?? "", "sess-b", "the session needing permission sorts first")
        // transcript status downgrade: stale transcript says running, no registry status
        let base2 = makeTmp("cl")
        let procs2 = FakeProcs()
        procs2.add(5001, tty: 3, start: started, path: claudeBin, cwd: "/work/old", argv: ["claude"])
        write(base2 + "/claude/sessions/5001.json", registryJSON(pid: 5001, sid: "sess-old", cwd: "/work/old", startedAt: started, status: nil))
        let op = base2 + "/claude/projects/\(claudeSlug("/work/old"))/sess-old.jsonl"
        write(op, jsonString(["type": "user", "timestamp": iso(now.addingTimeInterval(-3000)), "message": ["content": "long ago"]]) + "\n")
        setMTime(op, now.addingTimeInterval(-600))
        let res2 = DiscoveryRegistry(config: DiscoveryConfig(claudeDir: base2 + "/claude", codexDir: base2 + "/codex"), source: procs2).scan()
        eq(res2.sessions.first?.status ?? .unknown, .idle, "a transcript that says running but has been quiet for minutes is shown as idle")
        eq(res2.sessions.first?.statusDetail ?? "", "estimated from activity", "...and says the status is an estimate")
        eq(res2.sessions.first?.statusProvenance ?? .hook, .transcript, "...with transcript provenance")
    }

    section("Process-only sessions (no registry) and Codex rollouts")
    do {
        let base = makeTmp("po")
        let claudeDir = base + "/claude", codexDir = base + "/codex"
        let nowD = Date()
        let procs = FakeProcs()
        procs.add(6001, tty: 8, start: nowD.addingTimeInterval(-600), path: claudeBin, cwd: "/work/solo", argv: ["claude"])
        procs.add(6002, tty: 9, start: nowD.addingTimeInterval(-600), path: claudeBin, cwd: "/work/twin", argv: ["claude"])
        procs.add(6003, tty: 10, start: nowD.addingTimeInterval(-600), path: claudeBin, cwd: "/work/twin", argv: ["claude"])
        let solo = claudeDir + "/projects/\(claudeSlug("/work/solo"))/solo-id.jsonl"
        write(solo, jsonString(["type": "user", "timestamp": iso(nowD.addingTimeInterval(-10)), "message": ["content": "hello solo"]]) + "\n")
        for id in ["t1", "t2"] { write(claudeDir + "/projects/\(claudeSlug("/work/twin"))/\(id).jsonl", jsonString(["type": "user", "message": ["content": "x"]]) + "\n") }
        let res = DiscoveryRegistry(config: DiscoveryConfig(claudeDir: claudeDir, codexDir: codexDir), source: procs).scan()
        let ids = Set(res.sessions.map { $0.key.id })
        check(ids.contains("solo-id"), "an unambiguous process adopts the newest transcript in its cwd")
        check(ids.contains("pid:6002") && ids.contains("pid:6003"), "ambiguous processes (two in one cwd) stay pid-keyed rather than guessing")
        eq(res.sessions.first(where: { $0.key.id == "solo-id" })?.provenance ?? .hook, .processScan, "process-found session has processScan identity provenance")
        eq(res.sessions.first(where: { $0.key.id == "solo-id" })?.textProvenance ?? .hook, .transcript, "...and transcript text provenance")
        eq(res.sessions.first(where: { $0.key.id == "pid:6002" })?.status ?? .unknown, .idle, "a bare live process with no activity data is idle (estimated)")

        // Codex
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: nowD)
        let dayDir = codexDir + String(format: "/sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!)
        let id1 = "0198aaaa-bbbb-7ccc-8ddd-eeeeffff0001", id2 = "0198aaaa-bbbb-7ccc-8ddd-eeeeffff0002", id3 = "0198aaaa-bbbb-7ccc-8ddd-eeeeffff0003"
        let id4 = "0198aaaa-bbbb-7ccc-8ddd-eeeeffff0004", id5 = "0198aaaa-bbbb-7ccc-8ddd-eeeeffff0005"
        func rolloutFile(_ id: String, cwd: String, start: Date, lines: [[String: Any]] = [], compressed: Bool = false) -> String {
            let path = dayDir + "/rollout-2026-10-21T09-00-00-\(id).jsonl" + (compressed ? ".zst" : "")
            if compressed { writeData(path, Data([0x28, 0xB5, 0x2F, 0xFD, 0, 1, 2, 3])); return path }
            var all: [[String: Any]] = [Fx.rollout("session_meta", ["id": id, "cwd": cwd, "timestamp": iso(start)], ts: iso(start))]
            all += lines
            write(path, all.map { jsonString($0) }.joined(separator: "\n") + "\n")
            return path
        }
        let p1 = rolloutFile(id1, cwd: "/work/cx", start: nowD.addingTimeInterval(-500), lines: [
            Fx.eventMsg("user_message", ["message": "refactor parser"], ts: iso(nowD.addingTimeInterval(-60))),
            Fx.eventMsg("task_started", [:], ts: iso(nowD.addingTimeInterval(-59))),
            Fx.eventMsg("plan_update", ["plan": [["step": "Read", "status": "completed"], ["step": "Edit", "status": "in_progress"]]], ts: iso(nowD.addingTimeInterval(-50))),
            Fx.eventMsg("exec_approval_request", ["command": ["bash", "-lc", "make"]], ts: iso(nowD.addingTimeInterval(-40))),
        ])
        _ = p1
        _ = rolloutFile(id2, cwd: "/work/twinx", start: nowD.addingTimeInterval(-300), lines: [Fx.eventMsg("task_complete", ["last_agent_message": "done A"], ts: iso(nowD.addingTimeInterval(-100)))])
        _ = rolloutFile(id3, cwd: "/work/twinx", start: nowD.addingTimeInterval(-100), lines: [Fx.eventMsg("task_started", [:], ts: iso(nowD.addingTimeInterval(-30)))])
        _ = rolloutFile(id4, cwd: "/work/zst", start: nowD.addingTimeInterval(-200), compressed: true)
        let stale = rolloutFile(id5, cwd: "/work/ghost", start: nowD.addingTimeInterval(-7200), lines: [Fx.eventMsg("task_started")])
        setMTime(stale, nowD.addingTimeInterval(-7200))
        let cprocs = FakeProcs()
        cprocs.add(7001, tty: 11, start: nowD.addingTimeInterval(-520), path: "/opt/homebrew/bin/codex", cwd: "/work/cx", argv: ["codex"])
        cprocs.add(7002, tty: 12, start: nowD.addingTimeInterval(-310), path: "/opt/homebrew/bin/codex", cwd: "/work/twinx", argv: ["codex"])
        cprocs.add(7003, tty: 13, start: nowD.addingTimeInterval(-110), path: "/opt/homebrew/bin/codex", cwd: "/work/twinx", argv: ["codex"])
        cprocs.add(7004, tty: 14, start: nowD.addingTimeInterval(-210), path: "/opt/homebrew/bin/codex", cwd: "/work/zst", argv: ["codex"])
        cprocs.add(7005, tty: 15, start: nowD.addingTimeInterval(-210), path: "/opt/homebrew/bin/codex", cwd: "/work/nomatch", argv: ["codex"])
        let cres = DiscoveryRegistry(config: DiscoveryConfig(claudeDir: claudeDir, codexDir: codexDir), source: cprocs).scan()
        let cby = Dictionary(uniqueKeysWithValues: cres.sessions.filter { $0.key.kind == .codex }.map { ($0.key.id, $0) })
        let s1 = cby[id1]
        check(s1 != nil, "codex: process matched to its rollout by cwd")
        eq(s1?.pid ?? 0, 7001, "codex: pid carried"); eq(s1?.status ?? .unknown, .needsPermission, "codex: rollout approval request with nothing after it -> needsPermission")
        eq(s1?.tasks?.map { $0.status } ?? [], [.completed, .inProgress], "codex: plan_update checklist")
        eq(s1?.lastPrompt ?? "", "refactor parser", "codex: last prompt from the rollout"); eq(s1?.statusProvenance ?? .hook, .rollout, "codex: rollout status provenance")
        eq(s1?.tty ?? "", "/dev/ttys011", "codex: tty")
        eq(cby[id2]?.pid ?? 0, 7002, "codex: two sessions in one cwd are paired by start time (older)")
        eq(cby[id3]?.pid ?? 0, 7003, "codex: two sessions in one cwd are paired by start time (newer)")
        eq(cby[id2]?.status ?? .unknown, .idle, "codex: task_complete -> idle")
        check(cby[id3]?.status != nil, "codex: task_started gives a status")
        let zs = cby[id4]
        check(zs == nil || zs?.note != nil, "codex: a compressed rollout never crashes the scan")
        check(cres.sessions.contains(where: { $0.key.id == "pid:7004" }) || cby[id4] != nil, "codex: the process is still listed when its rollout is compressed")
        check(cres.sessions.contains(where: { $0.key.id == "pid:7005" }), "codex: a process with no matching rollout is listed under its pid")
        check(cby[id5] == nil, "codex: a stale unmatched rollout is not resurrected")
        // recently active rollout without a process of ours (e.g. desktop app thread)
        let id6 = "0198aaaa-bbbb-7ccc-8ddd-eeeeffff0006"
        _ = rolloutFile(id6, cwd: "/work/desktop-thread", start: nowD.addingTimeInterval(-30), lines: [Fx.eventMsg("task_started", [:], ts: iso(nowD.addingTimeInterval(-20)))])
        let cres2 = DiscoveryRegistry(config: DiscoveryConfig(claudeDir: claudeDir, codexDir: codexDir), source: cprocs).scan()
        let dt = cres2.sessions.first(where: { $0.key.id == id6 })
        check(dt != nil && dt?.pid == nil, "codex: a recently active rollout without a process is shown (no pid)")
        if case .deepLink(let url)? = dt?.jump { eq(url.absoluteString, "codex://threads/\(id6)", "codex: such a thread jumps via codex:// deep link") } else { check(false, "codex: desktop-thread jump target") }
    }

    section("TranscriptTail: tail-only reads, caching, tolerance")
    do {
        let dir = makeTmp("tt")
        let big = dir + "/big.jsonl"
        // ~50 MB of filler lines followed by the lines that matter.
        let filler = jsonString(["type": "assistant", "message": ["model": "m", "content": [["type": "text", "text": String(repeating: "filler ", count: 140)]]]]) + "\n"
        let fillerData = Data(filler.utf8)
        FileManager.default.createFile(atPath: big, contents: nil)
        let fh = FileHandle(forWritingAtPath: big)!
        var written = 0
        let chunk = Data(repeating: 0, count: 0) + (0..<500).reduce(into: Data()) { d, _ in d.append(fillerData) }
        while written < 50 * 1024 * 1024 { fh.write(chunk); written += chunk.count }
        fh.write(Data((jsonString(["type": "ai-title", "aiTitle": "Huge session title"]) + "\n" +
                       jsonString(["type": "user", "timestamp": iso(Date()), "message": ["content": "the final prompt"]]) + "\n" +
                       jsonString(["type": "assistant", "timestamp": iso(Date()), "message": ["model": "claude-opus-4-7", "stop_reason": "end_turn", "content": [["type": "text", "text": "Final answer"]]]]) + "\n").utf8))
        try? fh.close()
        let size = (try? FileManager.default.attributesOfItem(atPath: big)[.size] as? NSNumber)?.intValue ?? 0
        check(size > 50 * 1024 * 1024, "fixture is a 50 MB+ transcript (\(size / 1_048_576) MB)")
        let tail = TranscriptTail()
        let t0 = Date()
        let sum = tail.summarize(path: big, kind: .claudeCode, sessionID: "big")
        let dt = Date().timeIntervalSince(t0)
        check(sum != nil, "50 MB transcript summarised")
        check((sum?.bytesRead ?? Int.max) <= TranscriptTail.tailBytes, "only the last 512 KB were read (\(sum?.bytesRead ?? -1) bytes)")
        check(sum?.headTruncated == true, "the partial first line of the tail is dropped")
        check(dt < 1.0, "tail read of a 50 MB file is fast (\(String(format: "%.3f", dt)) s)")
        eq(sum?.title ?? "", "Huge session title", "title from the tail"); eq(sum?.lastPrompt ?? "", "the final prompt", "last prompt from the tail")
        eq(sum?.lastAssistantText ?? "", "Final answer", "assistant text from the tail"); eq(sum?.status ?? .unknown, .idle, "end_turn -> idle")
        eq(tail.readCount, 1, "first summarise reads the file once")
        _ = tail.summarize(path: big, kind: .claudeCode, sessionID: "big")
        eq(tail.readCount, 1, "unchanged mtime/size: served from the cache")
        let fh2 = FileHandle(forWritingAtPath: big)!; fh2.seekToEndOfFile()
        fh2.write(Data((jsonString(["type": "user", "timestamp": iso(Date()), "message": ["content": "appended prompt"]]) + "\n").utf8)); try? fh2.close()
        let sum2 = tail.summarize(path: big, kind: .claudeCode, sessionID: "big")
        eq(tail.readCount, 2, "a changed file is re-read"); eq(sum2?.lastPrompt ?? "", "appended prompt", "appended line is seen"); eq(sum2?.status ?? .unknown, .running, "a new prompt after end_turn -> running")

        check(tail.summarize(path: dir + "/missing.jsonl", kind: .claudeCode, sessionID: "x") == nil, "missing file -> nil")
        check(tail.summarize(path: dir, kind: .claudeCode, sessionID: "x") == nil, "a directory -> nil")
        write(dir + "/empty.jsonl", "")
        let es = tail.summarize(path: dir + "/empty.jsonl", kind: .claudeCode, sessionID: "e")
        check(es != nil && es?.status == nil && es?.title == nil, "empty file -> empty summary, no status")
        writeData(dir + "/bin.jsonl", Data((0..<20_000).map { _ in UInt8.random(in: 0...255) }))
        check(tail.summarize(path: dir + "/bin.jsonl", kind: .claudeCode, sessionID: "b") != nil, "binary garbage does not crash")
        write(dir + "/cut.jsonl", "{\"type\":\"user\",\"message\":{\"content\":\"complete\"}}\n{\"type\":\"user\",\"message\":{\"content\":\"trunc")
        eq(tail.summarize(path: dir + "/cut.jsonl", kind: .claudeCode, sessionID: "c")?.lastPrompt ?? "", "complete", "a truncated last line is ignored")
        let hugeLine = "{\"type\":\"user\",\"message\":{\"content\":\"" + String(repeating: "z", count: 600_000) + "\"}}\n" + jsonString(["type": "user", "message": ["content": "after the huge line"]]) + "\n"
        write(dir + "/hugeline.jsonl", hugeLine)
        eq(tail.summarize(path: dir + "/hugeline.jsonl", kind: .claudeCode, sessionID: "h")?.lastPrompt ?? "", "after the huge line", "a line larger than the tail window is skipped safely")
        write(dir + "/pending.jsonl", jsonString(["type": "assistant", "timestamp": iso(Date()), "message": ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "x1", "name": "Bash", "input": ["command": "sleep 100"]]]]]) + "\n")
        let ps = tail.summarize(path: dir + "/pending.jsonl", kind: .claudeCode, sessionID: "p")
        eq(ps?.status ?? .unknown, .running, "a tool_use without a result -> running"); eq(ps?.currentTool?.summary ?? "", "sleep 100", "...with that tool as the current activity")
        write(dir + "/done.jsonl", jsonString(["type": "assistant", "message": ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "x1", "name": "Bash", "input": ["command": "ls"]]]]]) + "\n" + jsonString(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "x1"]]]]) + "\n")
        check(tail.summarize(path: dir + "/done.jsonl", kind: .claudeCode, sessionID: "d")?.currentTool == nil, "a matching tool_result clears the current activity")
        write(dir + "/todos.jsonl", jsonString(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "w", "name": "TodoWrite", "input": ["todos": [["content": "One", "status": "completed"], ["content": "Two", "status": "in_progress", "activeForm": "Doing two"]]]]]]]) + "\n")
        eq(tail.summarize(path: dir + "/todos.jsonl", kind: .claudeCode, sessionID: "t")?.tasks?.map { $0.title } ?? [], ["One", "Two"], "TodoWrite in a transcript yields the checklist")
        // zst
        writeData(dir + "/rollout-x.jsonl.zst", Data([0x28, 0xB5, 0x2F, 0xFD, 1, 2, 3]))
        let zs = tail.summarize(path: dir + "/rollout-x.jsonl.zst", kind: .codex, sessionID: "z")
        check(zs?.compressed == true && (zs?.note ?? "").contains("zst"), ".zst rollout is detected and skipped with a note")
        // rollout meta
        let rp = dir + "/rollout-2026-10-21T09-00-00-0198aaaa-bbbb-7ccc-8ddd-eeeeffff0009.jsonl"
        write(rp, jsonString(Fx.rollout("session_meta", ["id": "0198aaaa-bbbb-7ccc-8ddd-eeeeffff0009", "cwd": "/work/meta", "timestamp": "2026-10-21T09:00:00.000Z"])) + "\n" + "garbage\n")
        let meta = tail.rolloutMeta(path: rp)
        eq(meta?.cwd ?? "", "/work/meta", "rollout meta: cwd from the first line"); check(meta?.startedAt != nil, "rollout meta: start time")
        check(tail.rolloutMeta(path: dir + "/nope.jsonl") == nil, "rollout meta of a missing file is nil")
        // codex summary with plan + approval then execution
        let cx = dir + "/cx.jsonl"
        write(cx, [Fx.rollout("session_meta", ["id": "i", "cwd": "/c"]), Fx.eventMsg("task_started"), Fx.eventMsg("exec_approval_request"), Fx.eventMsg("exec_command_begin", ["call_id": "1", "command": ["bash", "-lc", "ls"]])].map { jsonString($0) }.joined(separator: "\n") + "\n")
        eq(tail.summarize(path: cx, kind: .codex, sessionID: "i")?.status ?? .unknown, .running, "codex rollout: approval followed by exec_command_begin -> running")
        eq(tail.summarize(path: cx, kind: .codex, sessionID: "i")?.cwd ?? "", "/c", "codex rollout: cwd from session_meta")
    }

    section("Discovery polling policy")
    eq(DiscoveryLoop.delay(interval: 15, maxBackoff: 60, emptyScans: 0), 15, "delay: 15 s while something is found")
    eq(DiscoveryLoop.delay(interval: 15, maxBackoff: 60, emptyScans: 1), 30, "delay: 30 s after the first empty scan")
    eq(DiscoveryLoop.delay(interval: 15, maxBackoff: 60, emptyScans: 2), 60, "delay: 60 s when nothing keeps being found")
    eq(DiscoveryLoop.delay(interval: 15, maxBackoff: 60, emptyScans: 50), 60, "delay never exceeds the backoff cap")
    do {
        let scans = Atomic(0), found = Atomic(true)
        let loop = DiscoveryLoop(interval: 0.06, maxBackoff: 0.25, qos: .utility, scan: {
            scans.mutate { $0 += 1 }
            var d = DiscoveredSession(key: SessionKey(kind: .claudeCode, id: "x"), provenance: .registry, cwd: "/")
            d.pid = 1
            return DiscoveryResult(sessions: found.get() ? [d] : [], complete: true, notes: [])
        }, deliver: { _ in })
        await sleepMs(250)
        eq(scans.get(), 0, "nothing runs before start() (zero cost)")
        loop.start()
        check(await waitUntil(1) { scans.get() >= 1 }, "start() scans immediately")
        loop.start()
        check(await waitUntil(1) { scans.get() >= 3 }, "scans repeat on the interval")
        loop.stop()
        let afterStop = scans.get()
        await sleepMs(300)
        eq(scans.get(), afterStop, "stop() halts all scanning")
        found.set(false)
        let scans2 = Atomic(0)
        let loop2 = DiscoveryLoop(interval: 0.05, maxBackoff: 0.4, qos: .utility, scan: {
            scans2.mutate { $0 += 1 }
            return DiscoveryResult(sessions: [], complete: true, notes: [])
        }, deliver: { _ in })
        loop2.start()
        await sleepMs(700)
        check(scans2.get() <= 6, "empty scans back off (only \(scans2.get()) scans in 0.7 s with a 0.05 s base interval)")
        let before = scans2.get()
        loop2.refreshNow()
        check(await waitUntil(1) { scans2.get() > before }, "refreshNow() scans immediately even while backed off")
        loop2.stop()
        loop2.refreshNow()
        let after2 = scans2.get()
        await sleepMs(150)
        eq(scans2.get(), after2, "refreshNow() after stop() does nothing")
    }

    section("Real libproc (this process and spawned children)")
    do {
        let src = LibprocSource()
        let me = getpid()
        check(src.allPIDs().contains(me), "proc_listallpids includes this process")
        let b = src.basic(me)
        check(b != nil, "PROC_PIDTBSDINFO for this process")
        eq(b?.uid ?? 0, getuid(), "bsdinfo uid is ours"); eq(b?.ppid ?? 0, getppid(), "bsdinfo ppid is our parent")
        check(abs((b?.start.timeIntervalSinceNow ?? 9999)) < 600, "process start time is plausible")
        check((src.path(me) ?? "").hasSuffix("core-tests"), "proc_pidpath is this executable")
        let cwdNow = FileManager.default.currentDirectoryPath
        eq(((src.cwd(me) ?? "") as NSString).resolvingSymlinksInPath, (cwdNow as NSString).resolvingSymlinksInPath, "PROC_PIDVNODEPATHINFO cwd matches")
        let av = src.argv(me)
        check(av != nil && !(av?.isEmpty ?? true), "KERN_PROCARGS2 argv is readable for our own process")
        check(((av?.first ?? "") as NSString).lastPathComponent == "core-tests", "argv[0] is this executable")
        check(src.path(999_999) == nil && src.basic(999_999) == nil && src.cwd(999_999) == nil && src.argv(999_999) == nil, "nonexistent pid gives nil everywhere")
        check(ProcessLiveness.isAlive(pid: me, expectedStart: b?.start), "liveness: this process is alive")
        check(!ProcessLiveness.isAlive(pid: me, expectedStart: Date(timeIntervalSince1970: 1_000_000)), "liveness: a different start time means PID reuse")
        check(!ProcessLiveness.isAlive(pid: 999_999, expectedStart: nil), "liveness: nonexistent pid")
        check(!ProcessLiveness.isAlive(pid: 0, expectedStart: nil) && !ProcessLiveness.isAlive(pid: -5, expectedStart: nil), "liveness: pid 0 and negative pids are not alive")

        // A fake "claude" binary (a copy of this test binary in helper mode) started in a known cwd, found by the real scanner.
        let home = makeTmp("home")
        let versions = home + "/.local/share/claude/versions"
        try FileManager.default.createDirectory(atPath: versions, withIntermediateDirectories: true)
        let fake = versions + "/2.1.299"
        let selfPath = LibprocSource().path(getpid()) ?? CommandLine.arguments[0]
        try FileManager.default.copyItem(atPath: selfPath, toPath: fake)
        chmod(fake, 0o755)
        let work = makeTmp("work")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: fake)
        child.arguments = ["--aa-sleep", "30"]
        child.currentDirectoryURL = URL(fileURLWithPath: work)
        var spawned = true
        do { try child.run() } catch { spawned = false }
        if spawned {
            let pid = child.processIdentifier
            // The first exec of a freshly copied binary can take a while (code-signature checks): poll instead of sleeping.
            var found: AgentProcess?
            _ = await waitUntil(8) {
                found = ProcessScanner(source: LibprocSource(), uid: getuid(), apps: PlistAppResolver()).scan().agents.first(where: { $0.pid == pid })
                return found?.cwd != nil
            }
            check(found != nil, "real scan finds a claude-like process by its versions/ path")
            eq(found?.kind ?? .codex, .claudeCode, "...classified as claude")
            eq(((found?.cwd ?? "") as NSString).resolvingSymlinksInPath, (work as NSString).resolvingSymlinksInPath, "...with its real cwd")
            eq(found?.ppid ?? 0, me, "...and its real parent")
            check(ProcessLiveness.isAlive(pid: pid, expectedStart: found?.start), "liveness: the spawned child is alive")
            // Registry file for it + full discovery with the real process source
            let cdir = home + "/.claude"
            write(cdir + "/sessions/\(pid).json", registryJSON(pid: Int(pid), sid: "real-sess", cwd: work, startedAt: Date(), status: "busy"))
            var res = DiscoveryResult(sessions: [], complete: false, notes: [])
            _ = await waitUntil(5) {
                res = DiscoveryRegistry(config: DiscoveryConfig(claudeDir: cdir, codexDir: home + "/.codex"), source: LibprocSource()).scan()
                return res.sessions.contains(where: { $0.key.id == "real-sess" })
            }
            check(res.sessions.contains(where: { $0.key.id == "real-sess" && $0.pid == pid && $0.status == .running }), "registry + real process table: the live session is discovered (\(res.sessions.map { "\($0.key.id)/\($0.pid ?? -1)" }))")
            await reap(child)
            let res2 = DiscoveryRegistry(config: DiscoveryConfig(claudeDir: cdir, codexDir: home + "/.codex"), source: LibprocSource()).scan()
            check(!res2.sessions.contains(where: { $0.key.id == "real-sess" }), "after the process exits the stale registry file is ignored")
            check(!ProcessLiveness.isAlive(pid: pid, expectedStart: nil), "liveness: the exited child is gone")
        } else {
            check(true, "NOTE: could not exec the copied helper binary here; real-process classification skipped")
        }
    } catch { check(false, "real libproc section: \(error)") }

    section("Resource hygiene")
    do {
        let before = socketFDCount()
        let h = SrvHarness(name: "fd")
        try h.server.start()
        for i in 0..<60 {
            if let c = RawClient(path: h.path) {
                if i % 3 == 0 { c.send("{\"v\":1,\"agent\":\"claude\"}\n" + jsonString(Fx.claude("Stop"))); c.shutdownWrite() }
                else if i % 3 == 1 { c.send("garbage") }
                _ = c.readAll(timeout: 0.05)
                c.closeNow()
            }
        }
        check(await waitUntil(5) { h.server.connectionCount == 0 }, "all server connections released")
        h.server.stop()
        await sleepMs(100)
        let after = socketFDCount()
        check(after <= before, "no socket descriptor leak after 60 connections and a stop (\(before) -> \(after))")
    } catch { check(false, "fd hygiene: \(error)") }
}
