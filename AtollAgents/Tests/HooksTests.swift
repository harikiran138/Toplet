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

// Self-contained test runner for AtollAgents/Hooks (no XCTest, no Xcode). Build and run with
// AtollAgents/Tests/run_hooks.sh. Every file operation happens inside one temp directory through INJECTED paths
// (homeDirectory + environment: [:]); the real ~/.claude, ~/.codex and ~/.atoll are never touched.

var passed = 0
var failed = 0

func check(_ name: String, _ cond: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if cond() { passed += 1; print("PASS \(name)") }
    else { failed += 1; let d = detail(); print("FAIL \(name)" + (d.isEmpty ? "" : "  [\(d)]")) }
}

func section(_ s: String) { print("\n--- \(s)") }

// MARK: - Fixtures and helpers

let fm = FileManager.default
let root: String = {
    let base = NSTemporaryDirectory()
    var tmpl = Array((base + "ah-XXXXXX").utf8CString)
    let p = mkdtemp(&tmpl)!
    return String(cString: p)
}()

var caseCounter = 0
func newCase() -> (dir: URL, home: URL) {
    caseCounter += 1
    let dir = URL(fileURLWithPath: root + "/t\(caseCounter)")
    let home = dir.appendingPathComponent("h")
    try! fm.createDirectory(at: home, withIntermediateDirectories: true)
    return (dir, home)
}

final class Clock {
    var t = Date(timeIntervalSince1970: 1_800_000_000)
    func tick() -> Date { t += 1; return t }
}

func installer(_ home: URL, socket: String? = nil, env: [String: String] = [:], managed: String? = nil, clock: Clock = Clock()) -> HookInstaller {
    HookInstaller(homeDirectory: home, environment: env, socketPath: socket, managedClaudeSettingsPath: managed, now: { clock.tick() })
}

func write(_ text: String, to path: String, mode: mode_t = 0o644) {
    try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, mode)
}

func read(_ path: String) -> String? { (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) } }
func readData(_ path: String) -> Data? { try? Data(contentsOf: URL(fileURLWithPath: path)) }
func json(_ path: String) -> Any? { readData(path).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
func names(_ dir: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() }
func backups(of path: String) -> [String] {
    let prefix = (path as NSString).lastPathComponent + ".atoll-backup-"
    return names((path as NSString).deletingLastPathComponent).filter { $0.hasPrefix(prefix) }
}
func mode(of path: String) -> mode_t? { var st = stat(); return stat(path, &st) == 0 ? st.st_mode & 0o7777 : nil }
func isSymlink(_ path: String) -> Bool { var st = stat(); return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK }
func same(_ a: Any?, _ b: Any?) -> Bool { guard let a = a, let b = b else { return a == nil && b == nil }; return (a as AnyObject).isEqual(b) }
func hasTempLeftovers(_ dir: String) -> Bool { names(dir).contains { $0.contains(".atoll-tmp-") } }

func errorOf(_ body: () throws -> Any) -> HookInstallError? {
    do { _ = try body(); return nil } catch let e as HookInstallError { return e } catch { return .io(path: "", reason: "\(error)") }
}

func compact(_ json: String) -> JSONValue { try! OrderedJSON.parse(Data(json.utf8)).value }
func canonical(_ compactJSON: String) -> String { OrderedJSON.serialize(compact(compactJSON)) }

func topKeys(_ path: String) -> [String] {
    guard let d = readData(path), let v = try? OrderedJSON.parse(d).value, let m = v.objectValue else { return [] }
    return m.map { $0.key }
}

/// Atoll's exact commands for the default socket.
let claudeEntries = try! HookCommand.entries(for: .claudeCode)
let codexEntries = try! HookCommand.entries(for: .codex)
let claudeNB = HookCommand.command(agent: .claudeCode, blocking: false, socketLiteral: HookCommand.defaultSocketShellLiteral)
let claudePR = HookCommand.command(agent: .claudeCode, blocking: true, socketLiteral: HookCommand.defaultSocketShellLiteral)
let codexNB = HookCommand.command(agent: .codex, blocking: false, socketLiteral: HookCommand.defaultSocketShellLiteral)
let codexPR = HookCommand.command(agent: .codex, blocking: true, socketLiteral: HookCommand.defaultSocketShellLiteral)

// A rich pre-existing Claude settings file (compact form, converted to Claude Code's own JSON.stringify layout below).
let userSettingsCompact = """
{"$schema":"https://json.schemastore.org/claude-code-settings.json","model":"opus","env":{"FOO":"bar","BIG":12345678901234567890,"PI":3.10,"EXP":1E3},\
"permissions":{"allow":["Bash(npm run test *)","Read(~/docs/**)"],"deny":["Read(./.env)"],"defaultMode":"acceptEdits"},\
"statusLine":{"type":"command","command":"~/.claude/statusline.sh","padding":0},\
"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/bin/guard.sh","timeout":10}]}],\
"PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"prettier --write","timeout":5},{"type":"http","url":"http://localhost:8080/hook"}]}],\
"Stop":[{"hooks":[{"type":"prompt","prompt":"Check if done: $ARGUMENTS"}]}],\
"Notification":[{"matcher":"idle_prompt","hooks":[{"type":"command","command":"osascript -e 'display notification \\"hi\\"'"}]}]},\
"enabledPlugins":{"a@b":true},"unicode":"caf\\u00e9 \\ud83d\\ude00 é \\/ slash","emptyObj":{},"emptyArr":[],"nothing":null,"zebra":1,"alpha":2}
"""

func entryIsOurs(_ handler: Any, _ cmds: Set<String>) -> Bool {
    guard let h = handler as? [String: Any], let c = h["command"] as? String else { return false }
    return cmds.contains(c)
}

// MARK: - Fake hook server (unix socket)

final class FakeServer {
    let path: String
    var fd: Int32 = -1
    private let lock = NSLock()
    private var _received = [Data]()
    private var stopFlag = false
    let reply: Data?
    let holdOpenSeconds: Double
    let closeWithoutReading: Bool
    init(path: String, reply: String? = nil, holdOpenSeconds: Double = 0, closeWithoutReading: Bool = false) {
        self.path = path; self.reply = reply.map { Data($0.utf8) }
        self.holdOpenSeconds = holdOpenSeconds; self.closeWithoutReading = closeWithoutReading
    }
    var received: [Data] { lock.lock(); defer { lock.unlock() }; return _received }

    static func makeAddr(_ path: String) -> (sockaddr_un, socklen_t)? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in bytes.enumerated() { p[i] = b }; p[bytes.count] = 0 }
        return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    @discardableResult func start() -> Bool {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var (addr, len) = FakeServer.makeAddr(path) else { return false }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard r == 0, listen(fd, 8) == 0 else { return false }
        Thread.detachNewThread { [self] in loop() }
        return true
    }

    private func loop() {
        while true {
            lock.lock(); let stop = stopFlag; lock.unlock()
            if stop { return }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 100) <= 0 { continue }
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            Thread.detachNewThread { [self] in handle(c) }
        }
    }

    private func handle(_ c: Int32) {
        defer { close(c) }
        if closeWithoutReading { return }
        var all = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            all.append(buf, count: n)
        }
        lock.lock(); _received.append(all); lock.unlock()
        if let r = reply { _ = r.withUnsafeBytes { write(c, $0.baseAddress, r.count) } }
        if holdOpenSeconds > 0 { Thread.sleep(forTimeInterval: holdOpenSeconds) }
    }

    func stop() {
        lock.lock(); stopFlag = true; lock.unlock()
        Thread.sleep(forTimeInterval: 0.15)
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }
}

struct ShellResult { var status: Int32; var out: Data; var err: Data; var elapsed: Double; var timedOut: Bool }

func runShell(_ shell: String, _ command: String, stdin: Data, home: String, timeout: Double = 20) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: shell)
    p.arguments = ["-c", command]
    p.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
    let inPipe = Pipe()
    p.standardInput = inPipe
    let outPath = root + "/sh-out-\(UUID().uuidString.prefix(6))", errPath = root + "/sh-err-\(UUID().uuidString.prefix(6))"
    fm.createFile(atPath: outPath, contents: nil); fm.createFile(atPath: errPath, contents: nil)
    p.standardOutput = FileHandle(forWritingAtPath: outPath)
    p.standardError = FileHandle(forWritingAtPath: errPath)
    let t0 = Date()
    do { try p.run() } catch { return ShellResult(status: -1, out: Data(), err: Data("spawn failed \(error)".utf8), elapsed: 0, timedOut: false) }
    DispatchQueue.global().async {
        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
        try? inPipe.fileHandleForWriting.close()
    }
    var timedOut = false
    while p.isRunning {
        if Date().timeIntervalSince(t0) > timeout { timedOut = true; p.terminate(); break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    p.waitUntilExit()
    let el = Date().timeIntervalSince(t0)
    return ShellResult(status: p.terminationStatus, out: readData(outPath) ?? Data(), err: readData(errPath) ?? Data(), elapsed: el, timedOut: timedOut)
}

// MARK: - Test groups

func testCommandStrings() {
    section("HookCommand: pinned bytes")
    // PIN: Codex trusts hooks by hash. If any of these four literals must change, bump commandVersion and expect re-review.
    check("pin: Claude non-blocking command bytes", claudeNB ==
        #"S="$HOME/.atoll/run/agent.sock"; [ -S "$S" ] || exit 0; { printf '{"v":1,"agent":"claude","ppid":%s}\n' "$PPID"; cat; } | /usr/bin/nc -w 1 -U "$S" >/dev/null 2>&1; exit 0"#, claudeNB)
    check("pin: Claude PermissionRequest command bytes", claudePR ==
        #"S="$HOME/.atoll/run/agent.sock"; [ -S "$S" ] || exit 0; { printf '{"v":1,"agent":"claude","ppid":%s}\n' "$PPID"; cat; } | /usr/bin/nc -U "$S" 2>/dev/null; exit 0"#, claudePR)
    check("pin: Codex non-blocking command bytes", codexNB ==
        #"S="$HOME/.atoll/run/agent.sock"; [ -S "$S" ] || exit 0; { printf '{"v":1,"agent":"codex","ppid":%s}\n' "$PPID"; cat; } | /usr/bin/nc -w 1 -U "$S" >/dev/null 2>&1; exit 0"#, codexNB)
    check("pin: Codex PermissionRequest command bytes", codexPR ==
        #"S="$HOME/.atoll/run/agent.sock"; [ -S "$S" ] || exit 0; { printf '{"v":1,"agent":"codex","ppid":%s}\n' "$PPID"; cat; } | /usr/bin/nc -U "$S" 2>/dev/null; exit 0"#, codexPR)
    check("commandVersion is 1 (bump together with the pins above)", HookCommand.commandVersion == 1)
    check("entries(for:) uses exactly these strings (claude)", claudeEntries.allSatisfy { $0.command == ($0.blocking ? claudePR : claudeNB) })
    check("entries(for:) uses exactly these strings (codex)", codexEntries.allSatisfy { $0.command == ($0.blocking ? codexPR : codexNB) })
    check("entries are deterministic across calls", (try! HookCommand.entries(for: .claudeCode)) == claudeEntries)

    section("HookCommand: events and timeouts")
    check("Claude has the 18 events Toplet needs, in order", claudeEntries.map { $0.event } == [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
        "PermissionDenied", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "TeammateIdle", "TaskCreated", "TaskCompleted",
        "PreCompact", "PostCompact"])
    check("Codex has the 12 events", codexEntries.map { $0.event } == [
        "SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "PreToolUse", "PermissionRequest", "PostToolUse",
        "PreCompact", "PostCompact", "UserPromptSubmit", "Stop", "Interrupt"])
    check("only PermissionRequest is blocking (claude)", claudeEntries.filter { $0.blocking }.map { $0.event } == ["PermissionRequest"])
    check("only PermissionRequest is blocking (codex)", codexEntries.filter { $0.blocking }.map { $0.event } == ["PermissionRequest"])
    check("blocking command has no -w and passes stdout through", !claudePR.contains(" -w ") && !claudePR.contains(">/dev/null 2>&1") && claudePR.contains("2>/dev/null"))
    check("non-blocking command: nc -w 1, stdout+stderr discarded", claudeNB.contains("nc -w 1 -U") && claudeNB.contains(">/dev/null 2>&1"))
    check("every command ends with 'exit 0'", (claudeEntries + codexEntries).allSatisfy { $0.command.hasSuffix("; exit 0") })
    check("every command checks the socket first", (claudeEntries + codexEntries).allSatisfy { $0.command.contains("[ -S \"$S\" ] || exit 0") })
    check("no python and no newline in any command", (claudeEntries + codexEntries).allSatisfy { !$0.command.contains("python") && !$0.command.contains("\n") })
    check("claude header says agent claude, codex says codex", claudeNB.contains("\"agent\":\"claude\"") && codexNB.contains("\"agent\":\"codex\""))
    check("non-blocking claude events all share ONE string", Set(claudeEntries.filter { !$0.blocking }.map { $0.command }).count == 1)
    check("PermissionRequest timeout 900 > max approval timeout 600", HookCommand.permissionRequestTimeout == 900 && HookCommand.permissionRequestTimeout > HookCommand.maxApprovalTimeoutSeconds)
    check("SessionEnd timeout is tiny (2 s) for Claude", claudeEntries.first { $0.event == "SessionEnd" }?.timeout == 2)
    check("Codex SessionEnd/Interrupt timeouts within the documented 1-3 s", codexEntries.filter { $0.event == "SessionEnd" || $0.event == "Interrupt" }.allSatisfy { (1...3).contains($0.timeout) })
    check("other events use 3 s", claudeEntries.filter { !["SessionEnd", "PermissionRequest"].contains($0.event) }.allSatisfy { $0.timeout == 3 })

    section("HookCommand: custom socket path")
    check("default literal is used for nil", try! HookCommand.socketShellLiteral(nil) == "$HOME/.atoll/run/agent.sock")
    check("~/ expands to $HOME/", try! HookCommand.socketShellLiteral("~/s/a.sock", home: "/Users/x") == "$HOME/s/a.sock")
    check("$HOME/ prefix passes through", try! HookCommand.socketShellLiteral("$HOME/s/a.sock", home: "/Users/x") == "$HOME/s/a.sock")
    check("absolute path accepted", try! HookCommand.socketShellLiteral("/tmp/a.sock") == "/tmp/a.sock")
    check("shell metacharacters are escaped", try! HookCommand.socketShellLiteral("/tmp/a\"b$c`d\\e.sock") == "/tmp/a\\\"b\\$c\\`d\\\\e.sock")
    check("relative path rejected", (try? HookCommand.socketShellLiteral("a.sock")) == nil)
    check("empty path rejected", (try? HookCommand.socketShellLiteral("")) == nil)
    check("newline in path rejected", (try? HookCommand.socketShellLiteral("/tmp/a\nb")) == nil)
    check("path over the sun_path limit rejected", (try? HookCommand.socketShellLiteral("/" + String(repeating: "a", count: 120))) == nil)
    let custom = try! HookCommand.entries(for: .claudeCode, socketPath: "/tmp/my sock/a.sock")
    check("custom path appears in the command, quoted", custom[0].command.hasPrefix("S=\"/tmp/my sock/a.sock\"; "))
    check("custom path still ends with exit 0 and keeps structure", custom[0].command.hasSuffix("; exit 0") && custom[0].command != claudeNB)
    check("looksLikeAtoll recognises ours (any socket)", HookCommand.looksLikeAtoll(claudeNB, agent: .claudeCode) && HookCommand.looksLikeAtoll(custom[0].command, agent: .claudeCode))
    check("looksLikeAtoll does not match the other agent or an unrelated nc hook",
          !HookCommand.looksLikeAtoll(claudeNB, agent: .codex) && !HookCommand.looksLikeAtoll("/usr/bin/nc -U /tmp/x < /dev/null", agent: .claudeCode))
}

func testOrderedJSON() {
    section("OrderedJSON")
    let canon = """
    {
      "b": 1.50,
      "a": [
        1,
        {
          "x": null
        },
        []
      ],
      "s": "caf\\u00e9 \\/ \\ud83d\\ude00 é",
      "o": {},
      "t": true
    }

    """
    let (v, style) = try! OrderedJSON.parse(Data(canon.utf8))
    check("canonical (JSON.stringify 2-space) file round-trips byte-for-byte", OrderedJSON.serialize(v, style: style) == canon)
    check("member order preserved", v.objectValue?.map { $0.key } == ["b", "a", "s", "o", "t"])
    check("number tokens kept verbatim (1.50)", OrderedJSON.serialize(v, style: style).contains("1.50"))
    check("string escapes kept verbatim (\\u00e9, \\/ , surrogate pair)", OrderedJSON.serialize(v, style: style).contains("caf\\u00e9 \\/ \\ud83d\\ude00"))
    check("decoded string value is correct", v.objectValue?.first(key: "s")?.stringValue == "café / 😀 é")
    let big = canonical(#"{"n":12345678901234567890,"e":1E3,"neg":-0.0}"#)
    check("big integers / exponents / -0.0 survive", big.contains("12345678901234567890") && big.contains("1E3") && big.contains("-0.0"))
    let lone = canonical(#"{"s":"\ud800x"}"#)
    check("lone surrogate escape preserved verbatim", lone.contains("\\ud800x"))
    check("indent detection: tabs", { let (_, s) = try! OrderedJSON.parse(Data("{\n\t\"a\": 1\n}\n".utf8)); return s.indent == "\t" }())
    check("indent detection: 4 spaces", { let (_, s) = try! OrderedJSON.parse(Data("{\n    \"a\": 1\n}".utf8)); return s.indent == "    " && !s.trailingNewline }())
    check("CRLF detected and reproduced", { let (v2, s) = try! OrderedJSON.parse(Data("{\r\n  \"a\": 1\r\n}\r\n".utf8)); return OrderedJSON.serialize(v2, style: s) == "{\r\n  \"a\": 1\r\n}\r\n" }())
    check("minified input is pretty-printed (whitespace only changes)", canonical(#"{"a":[1,2]}"#) == "{\n  \"a\": [\n    1,\n    2\n  ]\n}\n")
    check("duplicate keys are kept (not merged)", compact(#"{"a":1,"a":2}"#).objectValue?.indices(ofKey: "a").count == 2)
    check("encodeString matches JSON.stringify escaping", OrderedJSON.encodeString("a\"b\\c\n\t\u{01}/é") == "\"a\\\"b\\\\c\\n\\t\\u0001/é\"")

    func rejects(_ name: String, _ s: String) {
        check("rejects \(name)", (try? OrderedJSON.parse(Data(s.utf8))) == nil)
    }
    rejects("trailing comma in object", #"{"a":1,}"#)
    rejects("trailing comma in array", #"{"a":[1,]}"#)
    rejects("// comment", "{\n// hi\n\"a\":1}")
    rejects("/* comment */", "{/*x*/\"a\":1}")
    rejects("single quotes", "{'a':1}")
    rejects("unquoted key", "{a:1}")
    rejects("NaN", #"{"a":NaN}"#)
    rejects("leading zero", #"{"a":01}"#)
    rejects("truncated file", #"{"a":{"b":[1,2"#)
    rejects("garbage after value", #"{"a":1} x"#)
    rejects("raw newline in string", "{\"a\":\"x\ny\"}")
    rejects("bad escape", #"{"a":"\x"}"#)
    rejects("nullx literal", #"{"a":nullx}"#)
    rejects("deep nesting (stack safety)", String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000))
    check("rejects invalid UTF-8", (try? OrderedJSON.parse(Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D]))) == nil)
    check("BOM accepted and remembered", { let (_, s) = try! OrderedJSON.parse(Data([0xEF, 0xBB, 0xBF] + Array("{}".utf8))); return s.bom }())
}

func testClaudeFreshInstall() {
    section("Claude: fresh install")
    let (dir, home) = newCase()
    let inst = installer(home)
    let path = inst.claudeSettingsPath
    check("default path is <home>/.claude/settings.json", path == home.path + "/.claude/settings.json")
    let report = try! inst.installWithReport(claude: true, codex: false)
    check("settings.json created", fm.fileExists(atPath: path))
    let c = report.files[0]
    check("report: created + wrote + 18 added + nothing present", c.created && c.wroteFile && c.added.count == 18 && c.alreadyPresent.isEmpty)
    check("report: no backup for a brand-new file", c.backupPath == nil && backups(of: path).isEmpty)
    check("report: only the Claude file", report.files.count == 1 && report.files[0].agent == .claudeCode)
    check("no Codex trust review for a Claude-only install", !report.needsCodexTrustReview)
    check("codex hooks.json NOT created", !fm.fileExists(atPath: inst.codexHooksPath))
    check("new settings file mode 0600", mode(of: path) == 0o600, "\(String(describing: mode(of: path)))")
    check("new config dir mode 0700", mode(of: home.path + "/.claude") == 0o700)
    let obj = json(path) as? [String: Any]
    let hooks = obj?["hooks"] as? [String: Any]
    check("valid JSON with hooks object", hooks != nil)
    check("18 event keys", hooks?.count == 18)
    var allGood = true
    for e in claudeEntries {
        let groups = hooks?[e.event] as? [[String: Any]]
        let hs = groups?.first?["hooks"] as? [[String: Any]]
        if groups?.count != 1 || hs?.count != 1 || hs?[0]["command"] as? String != e.command || hs?[0]["type"] as? String != "command" || (hs?[0]["timeout"] as? Int) != e.timeout { allGood = false }
    }
    check("each event: one group, one command handler with exact command + timeout", allGood)
    check("no matcher key written", !(read(path) ?? "").contains("\"matcher\""))
    check("file ends with newline, 2-space indent", (read(path) ?? "").hasSuffix("}\n") && (read(path) ?? "").contains("\n  \"hooks\": {"))
    check("no temp files left", !hasTempLeftovers(home.path + "/.claude"))
    check("state() -> installed(claude: true, codex: false)", inst.state() == .installed(claude: true, codex: false))
    check("detailedState claude installed / codex notInstalled", inst.detailedState() == HooksDetailedState(claude: .installed, codex: .notInstalled))
    check("HookInstaller conforms to HookInstalling", (inst as HookInstalling).state() == inst.state())
    _ = dir
}

func testClaudePreservation() {
    section("Claude: merge into the user's own settings")
    let (_, home) = newCase()
    let inst = installer(home)
    let path = inst.claudeSettingsPath
    let original = canonical(userSettingsCompact)
    write(original, to: path, mode: 0o640)
    let origObj = json(path)
    check("fixture is valid JSON", origObj != nil)
    let origKeys = topKeys(path)
    let before = readData(path)

    let rep = try! inst.installWithReport(claude: true, codex: false)
    let c = rep.files[0]
    check("install: wrote, not created, 13 added (4 events had user hooks, all 18 get ours)", c.wroteFile && !c.created && c.added.count == 18, "\(c.added.count)")
    check("a backup exists and equals the original bytes", c.backupPath != nil && readData(c.backupPath!) == before)
    check("exactly one backup file", backups(of: path).count == 1)
    check("backup mode is 0600", c.backupPath.flatMap { mode(of: $0) } == 0o600)
    check("file mode preserved (0640)", mode(of: path) == 0o640)
    let after = json(path) as? [String: Any]
    let orig = origObj as? [String: Any] ?? [:]
    for k in orig.keys where k != "hooks" { check("untouched key preserved: \(k)", same(orig[k], after?[k])) }
    check("top-level key ORDER preserved", topKeys(path) == origKeys, "\(topKeys(path))")
    check("statusLine untouched", same(orig["statusLine"], after?["statusLine"]))
    check("permissions untouched", same(orig["permissions"], after?["permissions"]))
    check("env untouched (incl. big integer text)", (read(path) ?? "").contains("12345678901234567890") && (read(path) ?? "").contains("3.10") && (read(path) ?? "").contains("1E3"))
    check("unicode strings kept verbatim", (read(path) ?? "").contains("caf\\u00e9 \\ud83d\\ude00 é \\/ slash"))
    let oh = orig["hooks"] as! [String: Any], nh = after?["hooks"] as! [String: Any]
    let cmds = Set(claudeEntries.map { $0.command })
    for (ev, groups) in oh {
        let og = groups as! [Any], ng = nh[ev] as! [Any]
        check("user's \(ev) groups unchanged and first", ng.count == og.count + 1 && same(Array(ng.prefix(og.count)), og))
        check("our \(ev) group appended last", entryIsOurs(((ng.last as? [String: Any])?["hooks"] as? [Any])?.first as Any, cmds))
    }
    check("events the user never had are created", nh["SessionStart"] != nil && nh["PermissionRequest"] != nil && nh.count == 18)
    check("user's http / prompt handlers intact", same((oh["PostToolUse"] as! [Any]).first, (nh["PostToolUse"] as! [Any]).first) && same((oh["Stop"] as! [Any]).first, (nh["Stop"] as! [Any]).first))

    section("Claude: idempotency")
    let afterBytes = readData(path)
    let rep2 = try! inst.installWithReport(claude: true, codex: false)
    check("second install: file byte-identical", readData(path) == afterBytes)
    check("second install: no new backup", backups(of: path).count == 1 && rep2.files[0].backupPath == nil)
    check("second install: nothing to change, 18 already present, not written", rep2.files[0].nothingToChange && rep2.files[0].alreadyPresent.count == 18 && !rep2.files[0].wroteFile)
    check("second install report summary says up to date", rep2.summary.contains("already up to date"))

    section("Claude: uninstall leaves only the user's content")
    let un = try! inst.uninstallWithReport()
    check("uninstall removed 18 events", un.files.first { $0.agent == .claudeCode }?.removed.count == 18)
    check("uninstalled file deep-equals the original", same(json(path), origObj))
    check("uninstalled file is BYTE-identical to the original (canonical layout round trip)", readData(path) == before)
    check("uninstall left backups (install + uninstall = 2)", backups(of: path).count == 2)
    check("state() -> notInstalled after uninstall", inst.state() == .notInstalled)
    let un2 = try! inst.uninstallWithReport()
    check("second uninstall: nothing to change, untouched", un2.files.allSatisfy { $0.nothingToChange && !$0.wroteFile } && readData(path) == before)
    check("second uninstall: no extra backup", backups(of: path).count == 2)
}

func testClaudeEdgeMerges() {
    section("Claude: same-event user hooks, shared groups, stale entries")
    let (_, home) = newCase()
    let inst = installer(home)
    let path = inst.claudeSettingsPath
    // a user hook that merely LOOKS similar, a group shared with an Atoll handler, a stale (older) Atoll command, an empty array, a non-array event of ours
    let lookalike = claudeNB.replacingOccurrences(of: "nc -w 1", with: "nc -w 2")   // different bytes => "stale" by signature
    let userSimilar = "/usr/bin/nc -w 1 -U /tmp/mine.sock < /dev/null; exit 0"
    let original = canonical("""
    {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":\(OrderedJSON.encodeString(userSimilar))},{"type":"command","command":\(OrderedJSON.encodeString(claudeNB)),"timeout":3}]}],
    "SessionStart":[{"hooks":[{"type":"command","command":\(OrderedJSON.encodeString(lookalike)),"timeout":3}]}],
    "Custom":[],"Stop":[{"hooks":[{"type":"command","command":"echo done"}]}]},"x":1}
    """)
    write(original, to: path)
    let rep = try! inst.installWithReport(claude: true, codex: false)
    let c = rep.files[0]
    check("PreToolUse: our handler already inside a user group counts as present", c.alreadyPresent == ["PreToolUse"], "\(c.alreadyPresent)")
    check("older Toplet entry on SessionStart reported as stale + replaced", c.staleRemoved == ["SessionStart"] && c.added.contains("SessionStart"))
    let h = (json(path) as! [String: Any])["hooks"] as! [String: Any]
    check("lookalike user command untouched", ((((h["PreToolUse"] as! [Any])[0] as! [String: Any])["hooks"] as! [[String: Any]])[0]["command"] as? String) == userSimilar)
    check("stale command no longer present anywhere", !(read(path) ?? "").contains("nc -w 2"))
    check("user's empty Custom array kept; Stop group kept", (h["Custom"] as? [Any])?.isEmpty == true && (h["Stop"] as! [Any]).count == 2)
    check("PreToolUse still has exactly one group (no duplicate added)", (h["PreToolUse"] as! [Any]).count == 1)
    check("SessionStart has exactly one group with our exact command", ((h["SessionStart"] as! [Any]).count == 1) && entryIsOurs((((h["SessionStart"] as! [Any])[0] as! [String: Any])["hooks"] as! [Any])[0], [claudeNB]))

    let un = try! inst.uninstallWithReport()
    let after = (json(path) as! [String: Any])
    let h2 = after["hooks"] as! [String: Any]
    check("uninstall: PreToolUse group survives with only the user's handler", (((h2["PreToolUse"] as! [Any])[0] as! [String: Any])["hooks"] as! [Any]).count == 1)
    check("uninstall: events we created are gone, user's remain", Set(h2.keys) == ["PreToolUse", "Custom", "Stop"], "\(h2.keys.sorted())")
    check("uninstall: user's unrelated key kept", after["x"] as? Int == 1)
    check("uninstall report lists removed events", un.files.first { $0.agent == .claudeCode }!.removed.count == 18)

    section("Claude: uninstall removes other-socket and older Toplet commands")
    let (_, home2) = newCase()
    let customInst = installer(home2, socket: "/tmp/atoll-other.sock")
    let defaultInst = installer(home2)
    try! customInst.installWithReport(claude: true, codex: false)
    check("custom-socket install writes the custom command", (read(customInst.claudeSettingsPath) ?? "").contains("S=\\\"/tmp/atoll-other.sock\\\"") || (read(customInst.claudeSettingsPath) ?? "").contains("/tmp/atoll-other.sock"))
    check("state with the DEFAULT socket installer: exact match fails -> notInstalled", defaultInst.state() == .notInstalled)
    check("state with the custom installer: installed", customInst.state() == .installed(claude: true, codex: false))
    try! defaultInst.uninstallWithReport()
    check("default-socket uninstall still removes the custom-socket Toplet entries", !(read(defaultInst.claudeSettingsPath) ?? "").contains("atoll-other"))
    check("...leaving a valid, empty settings object", (json(defaultInst.claudeSettingsPath) as? [String: Any])?.isEmpty == true)
    // switching socket path = replace, not duplicate
    try! customInst.installWithReport(claude: true, codex: false)
    let sw = try! defaultInst.installWithReport(claude: true, codex: false)
    check("re-install with another socket replaces stale entries (18 stale, 18 added)", sw.files[0].staleRemoved.count == 18 && sw.files[0].added.count == 18)
    check("exactly one group per event after switching", ((json(defaultInst.claudeSettingsPath) as! [String: Any])["hooks"] as! [String: [Any]]).allSatisfy { $0.value.count == 1 })
}

func testClaudeRefusals() {
    section("Claude: refuses unparseable / unexpected files (never starts from {})")
    func refusal(_ name: String, _ content: Data, expect: (HookInstallError) -> Bool) {
        let (_, home) = newCase()
        let inst = installer(home)
        let path = inst.claudeSettingsPath
        try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! content.write(to: URL(fileURLWithPath: path))
        let e = errorOf { try inst.installWithReport(claude: true, codex: true) }
        check("\(name): install throws the right error", e.map(expect) ?? false, "\(String(describing: e))")
        check("\(name): file unchanged", readData(path) == content)
        check("\(name): no backup noise", backups(of: path).isEmpty)
        check("\(name): no temp files", !hasTempLeftovers((path as NSString).deletingLastPathComponent))
        check("\(name): codex file not written either (preflight)", !fm.fileExists(atPath: inst.codexHooksPath))
        let u = errorOf { try inst.uninstallWithReport() }
        check("\(name): uninstall refuses too", u != nil && readData(path) == content)
        check("\(name): state() tolerant -> notInstalled", inst.state() == .notInstalled)
        if case .unreadable = inst.detailedState().claude { check("\(name): detailedState says unreadable", true) } else if name.contains("shape") { check("\(name): detailedState says unreadable", true) } else { check("\(name): detailedState says unreadable", false) }
        let pv = inst.preview()
        check("\(name): preview says it cannot change the file", pv.contains("Cannot change this file"))
    }
    func isUnparseable(_ e: HookInstallError) -> Bool { if case .unparseable = e { return true }; return false }
    func isShape(_ e: HookInstallError) -> Bool { if case .unexpectedShape = e { return true }; return false }
    refusal("trailing comma", Data(#"{"a":1,}"#.utf8), expect: isUnparseable)
    refusal("comments", Data("{\n // my settings\n \"a\": 1\n}".utf8), expect: isUnparseable)
    refusal("truncated", Data(#"{"hooks":{"Stop":["#.utf8), expect: isUnparseable)
    refusal("not JSON at all", Data("hello world".utf8), expect: isUnparseable)
    refusal("invalid UTF-8", Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xFF, 0xFE, 0x22, 0x7D]), expect: isUnparseable)
    refusal("top-level array (shape)", Data("[1,2]".utf8), expect: isShape)
    refusal("hooks is an array (shape)", Data(#"{"hooks":[]}"#.utf8), expect: isShape)
    refusal("event is not an array (shape)", Data(#"{"hooks":{"PreToolUse":{"a":1}}}"#.utf8), expect: isShape)
    refusal("duplicate hooks key (shape)", Data(#"{"hooks":{},"hooks":{}}"#.utf8), expect: isShape)
    refusal("duplicate event key (shape)", Data(#"{"hooks":{"Stop":[],"Stop":[]}}"#.utf8), expect: isShape)

    section("Claude: read-only, empty, BOM, symlink, mode")
    if geteuid() != 0 {
        let (_, home) = newCase()
        let inst = installer(home)
        let path = inst.claudeSettingsPath
        write(canonical(#"{"model":"x"}"#), to: path, mode: 0o444)
        let before = readData(path)
        let e = errorOf { try inst.installWithReport(claude: true, codex: false) }
        check("read-only file: install throws readOnly", { if case .readOnly? = e { return true }; return false }(), "\(String(describing: e))")
        check("read-only file: unchanged, no backup, no temp", readData(path) == before && backups(of: path).isEmpty && !hasTempLeftovers(home.path + "/.claude"))
        check("read-only file: preview explains", inst.preview().contains("read-only"))
        check("read-only file: state() still works", inst.state() == .notInstalled)
        chmod(path, 0o644)
    } else { print("SKIP read-only tests (running as root)") }

    do {
        let (_, home) = newCase()
        let inst = installer(home)
        let path = inst.claudeSettingsPath
        write("", to: path, mode: 0o600)
        try! inst.installWithReport(claude: true, codex: false)
        check("empty file: install works, valid JSON, 18 events", ((json(path) as? [String: Any])?["hooks"] as? [String: Any])?.count == 18)
        check("empty file: backup of the empty file exists", backups(of: path).count == 1 && readData(backups(of: path).first.map { (path as NSString).deletingLastPathComponent + "/" + $0 }!)?.isEmpty == true)
        try! inst.uninstallWithReport()
        check("empty file: uninstall leaves a valid empty object", (json(path) as? [String: Any])?.isEmpty == true)
    }
    do {
        let (_, home) = newCase()
        let inst = installer(home)
        let path = inst.claudeSettingsPath
        write("  \n\n ", to: path)
        try! inst.installWithReport(claude: true, codex: false)
        check("whitespace-only file treated as empty", ((json(path) as? [String: Any])?["hooks"] as? [String: Any])?.count == 18)
    }
    do {
        let (_, home) = newCase()
        let inst = installer(home)
        let path = inst.claudeSettingsPath
        let orig = Data([0xEF, 0xBB, 0xBF]) + Data(canonical(#"{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}"#).utf8)
        try! fm.createDirectory(atPath: home.path + "/.claude", withIntermediateDirectories: true)
        try! orig.write(to: URL(fileURLWithPath: path))
        try! inst.installWithReport(claude: true, codex: false)
        let d = readData(path)!
        check("BOM: preserved at the start of the file", d.starts(with: [0xEF, 0xBB, 0xBF]))
        check("BOM: valid JSON after the BOM with 18 events", ((try? JSONSerialization.jsonObject(with: d.dropFirst(3))) as? [String: Any]).flatMap { ($0["hooks"] as? [String: Any])?.count } == 18)
        try! inst.uninstallWithReport()
        check("BOM: install + uninstall is byte-identical", readData(path) == orig)
    }
    do {
        let (dir, home) = newCase()
        let inst = installer(home)
        let real = dir.path + "/dotfiles/claude-settings.json"
        let orig = canonical(#"{"model":"x"}"#)
        write(orig, to: real, mode: 0o640)
        try! fm.createDirectory(atPath: home.path + "/.claude", withIntermediateDirectories: true)
        try! fm.createSymbolicLink(atPath: inst.claudeSettingsPath, withDestinationPath: real)
        let rep = try! inst.installWithReport(claude: true, codex: false)
        check("symlink: settings.json is STILL a symlink", isSymlink(inst.claudeSettingsPath))
        check("symlink: still points at the same target", (try? fm.destinationOfSymbolicLink(atPath: inst.claudeSettingsPath)) == real)
        check("symlink: the target file was updated", ((json(real) as? [String: Any])?["hooks"] as? [String: Any])?.count == 18)
        check("symlink: mode of the target preserved", mode(of: real) == 0o640)
        check("symlink: backup lives next to the link", rep.files[0].backupPath.map { $0.hasPrefix(home.path + "/.claude/settings.json.atoll-backup-") } ?? false)
        check("symlink: no temp files in the target dir", !hasTempLeftovers(dir.path + "/dotfiles"))
        check("symlink: state sees through the link", inst.state() == .installed(claude: true, codex: false))
        try! inst.uninstallWithReport()
        check("symlink: uninstall round-trips the target bytes", read(real) == orig && isSymlink(inst.claudeSettingsPath))
    }
    do {
        let (dir, home) = newCase()
        let inst = installer(home)
        let real = dir.path + "/dotfiles/dangling.json"
        try! fm.createDirectory(atPath: dir.path + "/dotfiles", withIntermediateDirectories: true)
        try! fm.createDirectory(atPath: home.path + "/.claude", withIntermediateDirectories: true)
        try! fm.createSymbolicLink(atPath: inst.claudeSettingsPath, withDestinationPath: real)
        try! inst.installWithReport(claude: true, codex: false)
        check("dangling symlink: target created through the link, link kept", isSymlink(inst.claudeSettingsPath) && fm.fileExists(atPath: real))
    }
    do {
        let (_, home) = newCase()
        let inst = installer(home)
        write(canonical(#"{"a":1}"#), to: inst.claudeSettingsPath)
        let e = errorOf { try installer(home, socket: "relative.sock").installWithReport(claude: true, codex: true) }
        check("invalid socket path: install throws invalidSocketPath", { if case .invalidSocketPath? = e { return true }; return false }())
        check("invalid socket path: nothing written", read(inst.claudeSettingsPath) == canonical(#"{"a":1}"#) && backups(of: inst.claudeSettingsPath).isEmpty)
    }
}

func testHugeAndBackups() {
    section("Claude: huge file")
    do {
        let (_, home) = newCase()
        let inst = installer(home)
        let path = inst.claudeSettingsPath
        var allow = [String]()
        allow.reserveCapacity(120_000)
        for i in 0..<120_000 { allow.append("\"Bash(npm run task-\(i) --flag=\(i % 7))\"") }
        let text = "{\n  \"permissions\": {\n    \"allow\": [\n      " + allow.joined(separator: ",\n      ") + "\n    ]\n  },\n  \"model\": \"x\"\n}\n"
        write(text, to: path)
        let size = readData(path)!.count
        let t0 = Date()
        try! inst.installWithReport(claude: true, codex: false)
        let dt = Date().timeIntervalSince(t0)
        check("huge (\(size / 1_048_576) MiB, 120k entries) install finishes in < 20 s", dt < 20, "\(dt) s")
        let after = json(path) as? [String: Any]
        check("huge: all 120000 permission entries preserved", ((after?["permissions"] as? [String: Any])?["allow"] as? [Any])?.count == 120_000)
        check("huge: hooks added", (after?["hooks"] as? [String: Any])?.count == 18)
        try! inst.uninstallWithReport()
        check("huge: uninstall restores identical bytes", read(path) == text)
        check("huge: preview works on a big file", installer(home).preview().contains("@@"))
    }
    do {
        let (_, home) = newCase()
        let inst = installer(home)
        let path = inst.claudeSettingsPath
        try! fm.createDirectory(atPath: home.path + "/.claude", withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: nil)
        let h = FileHandle(forWritingAtPath: path)!
        try! h.truncate(atOffset: UInt64(HooksFileIO.maxFileBytes) + 10)   // sparse
        try! h.close()
        let e = errorOf { try inst.installWithReport(claude: true, codex: false) }
        check("file over 64 MiB refused as unparseable", { if case .unparseable? = e { return true }; return false }(), "\(String(describing: e))")
        check("file over 64 MiB: no backup, size unchanged", backups(of: path).isEmpty && (try? fm.attributesOfItem(atPath: path)[.size] as? UInt64) == UInt64(HooksFileIO.maxFileBytes) + 10)
    }

    section("Backups: timestamp names, rotation to 5, collisions")
    do {
        let (_, home) = newCase()
        let clock = Clock()
        let inst = installer(home, clock: clock)
        let path = inst.claudeSettingsPath
        write(canonical(#"{"model":"x"}"#), to: path)
        var made = [String]()
        for i in 0..<8 {
            let r = i % 2 == 0 ? try! inst.installWithReport(claude: true, codex: false) : try! inst.uninstallWithReport()
            if let b = r.files.first(where: { $0.agent == .claudeCode })?.backupPath { made.append(b) }
        }
        check("8 writing operations made 8 backups", made.count == 8)
        let left = backups(of: path)
        check("only the newest 5 backups are kept", left.count == 5, "\(left.count)")
        check("kept = the last 5 made", made.suffix(5).allSatisfy { fm.fileExists(atPath: $0) } && made.prefix(3).allSatisfy { !fm.fileExists(atPath: $0) })
        check("backup names are <file>.atoll-backup-YYYYMMDD-HHMMSS", left.allSatisfy { HooksFileIO.isBackupName($0, prefix: "settings.json.atoll-backup-") && $0.count == "settings.json.atoll-backup-".count + 15 })
        write("keep me", to: home.path + "/.claude/settings.json.atoll-backup-notes")
        write("keep me too", to: home.path + "/.claude/settings.json.bak")
        _ = try! inst.installWithReport(claude: true, codex: false)
        _ = try! inst.uninstallWithReport()
        check("rotation never deletes files that do not match the backup pattern", fm.fileExists(atPath: home.path + "/.claude/settings.json.atoll-backup-notes") && fm.fileExists(atPath: home.path + "/.claude/settings.json.bak"))
    }
    do {
        let (_, home) = newCase()
        let fixed = { Date(timeIntervalSince1970: 1_800_000_000) }
        let inst = HookInstaller(homeDirectory: home, environment: [:], socketPath: nil, managedClaudeSettingsPath: nil, now: fixed)
        let path = inst.claudeSettingsPath
        write(canonical(#"{"model":"x"}"#), to: path)
        try! inst.installWithReport(claude: true, codex: false)
        try! inst.uninstallWithReport()
        try! inst.installWithReport(claude: true, codex: false)
        let b = backups(of: path)
        check("three writes inside the same second give three distinct backups", b.count == 3 && Set(b).count == 3, "\(b)")
        check("collision names get a -NN suffix", b.filter { $0.count > "settings.json.atoll-backup-".count + 15 }.count == 2)
    }
    do {
        let (_, home) = newCase()
        let inst = installer(home)
        let path = inst.claudeSettingsPath
        write(canonical(#"{"a":1}"#), to: path)
        let ed = try! ClaudeSettingsEditor(settingsPath: path, entries: HookCommand.entries(for: .claudeCode), managedSettingsPath: nil)
        let plan = try! ed.plan(.install)
        let changed = canonical(#"{"a":2}"#)
        write(changed, to: path)        // Claude Code (or the user) writes between plan and commit
        let e = errorOf { try ed.commit(plan) }
        check("concurrent modification detected: modifiedConcurrently", { if case .modifiedConcurrently? = e { return true }; return false }(), "\(String(describing: e))")
        check("concurrent modification: the other writer's content survives", read(path) == changed)
        check("concurrent modification: no backup noise, no temp files", backups(of: path).isEmpty && !hasTempLeftovers(home.path + "/.claude"))
    }
}

func testWarnings() {
    section("Claude: disableAllHooks / allowManagedHooksOnly / managed policy")
    let (dir, home) = newCase()
    let inst = installer(home)
    write(canonical(#"{"disableAllHooks":true,"allowManagedHooksOnly":true,"model":"x"}"#), to: inst.claudeSettingsPath)
    let r = try! inst.installWithReport(claude: true, codex: false)
    check("disableAllHooks reported as a warning", r.warnings.contains { $0.contains("disableAllHooks") && $0.contains("no hooks") })
    check("allowManagedHooksOnly reported as a warning", r.warnings.contains { $0.contains("allowManagedHooksOnly") })
    check("install still happened (user's choice to flip the flag)", r.files[0].wroteFile && (json(inst.claudeSettingsPath) as? [String: Any])?["disableAllHooks"] as? Bool == true)
    check("preview shows the warning too", installer(home).preview().contains("disableAllHooks"))
    let (dir2, home2) = newCase()
    let managed = dir2.path + "/managed-settings.json"
    write(#"{"allowManagedHooksOnly": true}"#, to: managed)
    let inst2 = installer(home2, managed: managed)
    let r2 = try! inst2.installWithReport(claude: true, codex: false)
    check("managed policy allowManagedHooksOnly reported", r2.warnings.contains { $0.contains("Managed policy") && $0.contains("will NOT run") })
    check("managed file never modified", read(managed) == #"{"allowManagedHooksOnly": true}"#)
    check("missing managed file: no warning, no failure", { let (_, h3) = newCase(); return (try? installer(h3, managed: "/nonexistent/managed.json").installWithReport(claude: true, codex: false))?.warnings.isEmpty == true }())
    _ = dir
}

func testCodex() {
    section("Codex: hooks.json install / merge / uninstall")
    let (_, home) = newCase()
    let inst = installer(home)
    let path = inst.codexHooksPath
    check("default path is <home>/.codex/hooks.json", path == home.path + "/.codex/hooks.json")
    let r = try! inst.installWithReport(claude: false, codex: true)
    let c = r.files[0]
    check("fresh Codex install: created, 12 added", c.created && c.added.count == 12 && c.wroteFile && c.agent == .codex)
    check("needsCodexTrustReview is true and the warning mentions /hooks", r.needsCodexTrustReview && r.warnings.contains { $0.contains("/hooks") })
    let obj = json(path) as? [String: Any]
    let hooks = obj?["hooks"] as? [String: Any]
    check("hooks.json top level has only 'hooks'", obj?.keys.sorted() == ["hooks"])
    check("12 event keys", hooks?.count == 12)
    var ok = true
    for e in codexEntries {
        let hs = ((hooks?[e.event] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        if hs?.count != 1 || hs?[0]["command"] as? String != e.command || hs?[0]["type"] as? String != "command" || hs?[0]["timeout"] as? Int != e.timeout { ok = false }
    }
    check("each Codex event carries the exact command and timeout", ok)
    check("PermissionRequest handler uses the 900 s timeout", (((hooks?["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int) == 900)
    check("Codex file is separate from Claude's (not created)", !fm.fileExists(atPath: inst.claudeSettingsPath))
    let again = try! inst.installWithReport(claude: false, codex: true)
    check("Codex idempotent: untouched, no trust re-review requested", again.files[0].nothingToChange && !again.files[0].wroteFile && !again.needsCodexTrustReview)
    check("Codex state installed", inst.state() == .installed(claude: false, codex: true))
    try! inst.uninstallWithReport()
    check("Codex uninstall of a file we created leaves an empty object", (json(path) as? [String: Any])?.isEmpty == true)

    section("Codex: merge with the user's own hooks.json")
    let (_, home2) = newCase()
    let inst2 = installer(home2)
    let user = canonical(#"{"description":"my hooks","hooks":{"PreToolUse":[{"matcher":"^Bash$","hooks":[{"type":"command","command":"python3 ~/.codex/hooks/check.py","timeout":30,"statusMessage":"Checking"}]}],"PostToolUse":[{"matcher":"Write|Edit","hooks":[{"type":"command","command":"x","async":true,"timeout":120},{"type":"mcp_tool","server":"scanner","tool":"scan","input":{"patch":"${tool_input.command}"}}]}]},"z":1}"#)
    write(user, to: inst2.codexHooksPath)
    let before = readData(inst2.codexHooksPath)
    let r2 = try! inst2.installWithReport(claude: false, codex: true)
    check("existing hooks.json: backup equals original", r2.files[0].backupPath.flatMap { readData($0) } == before)
    let o2 = json(inst2.codexHooksPath) as! [String: Any]
    check("description and unknown keys preserved", o2["description"] as? String == "my hooks" && o2["z"] as? Int == 1)
    check("key order preserved (description, hooks, z)", topKeys(inst2.codexHooksPath) == ["description", "hooks", "z"])
    let h2 = o2["hooks"] as! [String: Any]
    check("user's PreToolUse group first, ours appended", (h2["PreToolUse"] as! [Any]).count == 2)
    check("user's mcp_tool handler untouched", same(((h2["PostToolUse"] as! [Any])[0] as! [String: Any])["hooks"], ((json(backups(of: inst2.codexHooksPath).first.map { (inst2.codexHooksPath as NSString).deletingLastPathComponent + "/" + $0 }!) as! [String: Any])["hooks"] as! [String: Any])["PostToolUse"].map { ($0 as! [Any])[0] as! [String: Any] }?["hooks"]))
    try! inst2.uninstallWithReport()
    check("Codex uninstall: byte-identical to the user's original", readData(inst2.codexHooksPath) == before)

    section("Codex: refusals and config.toml (read-only scan)")
    let (_, home3) = newCase()
    let inst3 = installer(home3)
    write(#"{"hooks":{"Stop":[}"#, to: inst3.codexHooksPath)
    let e = errorOf { try inst3.installWithReport(claude: false, codex: true) }
    check("unparseable hooks.json refused", { if case .unparseable? = e { return true }; return false }())
    check("unparseable hooks.json: unchanged, no backup", read(inst3.codexHooksPath) == #"{"hooks":{"Stop":[}"# && backups(of: inst3.codexHooksPath).isEmpty)
    let (_, home4) = newCase()
    let inst4 = installer(home4)
    let toml = "model = \"gpt-5\"\n\n[features]\nhooks = false\n\n[[hooks.PreToolUse]]\nmatcher = \"^Bash$\"\n\n[[hooks.PreToolUse.hooks]]\ntype = \"command\"\ncommand = \"echo\"\n"
    write(toml, to: home4.path + "/.codex/config.toml")
    let r4 = try! inst4.installWithReport(claude: false, codex: true)
    check("config.toml with inline [[hooks.*]] -> warning (docs: one representation per layer)", r4.warnings.contains { $0.contains("inline [hooks]") })
    check("config.toml with [features] hooks = false -> warning", r4.warnings.contains { $0.contains("hooks = false") })
    check("config.toml is NEVER modified", read(home4.path + "/.codex/config.toml") == toml)
    check("config.toml scan: clean file gives no warnings", CodexHooksEditor.scanConfigToml(path: home3.path + "/nonexistent.toml").isEmpty)
    let (_, home5) = newCase()
    write("[features]\ncodex_hooks = false # nope\n", to: home5.path + "/.codex/config.toml")
    check("deprecated codex_hooks = false also detected", CodexHooksEditor.scanConfigToml(path: home5.path + "/.codex/config.toml").contains { $0.contains("hooks = false") })
    write("[tui]\nnotifications = true\n[features]\nhooks = true\n", to: home5.path + "/.codex/config.toml")
    check("hooks = true and unrelated tables give no warning", CodexHooksEditor.scanConfigToml(path: home5.path + "/.codex/config.toml").isEmpty)

    section("Both agents together")
    let (_, home6) = newCase()
    let inst6 = installer(home6)
    let both = try! inst6.installWithReport(claude: true, codex: true)
    check("both: two file reports, claude first", both.files.map { $0.agent } == [.claudeCode, .codex])
    check("both: state installed for both", inst6.state() == .installed(claude: true, codex: true))
    check("both: summary mentions both agents", both.summary.contains("Claude Code") && both.summary.contains("Codex"))
    let un = try! inst6.uninstallWithReport()
    check("both: uninstall removes from both", un.files.allSatisfy { $0.wroteFile } && inst6.state() == .notInstalled)

    section("Preflight: a later failure must not leave an earlier file written")
    if geteuid() != 0 {
        let (_, home7) = newCase()
        let inst7 = installer(home7)
        try! fm.createDirectory(atPath: home7.path + "/.codex", withIntermediateDirectories: true)
        chmod(home7.path + "/.codex", 0o555)
        let e7 = errorOf { try inst7.installWithReport(claude: true, codex: true) }
        check("codex dir not writable: install throws notWritable", { if case .notWritable? = e7 { return true }; return false }(), "\(String(describing: e7))")
        check("...and the Claude file was NOT written", !fm.fileExists(atPath: inst7.claudeSettingsPath))
        chmod(home7.path + "/.codex", 0o755)
    } else { print("SKIP preflight permission test (root)") }
}

func testEnvironment() {
    section("Config dir resolution: CLAUDE_CONFIG_DIR / CODEX_HOME")
    let (dir, home) = newCase()
    let cc = dir.path + "/cc", ch = dir.path + "/ch"
    let inst = installer(home, env: ["CLAUDE_CONFIG_DIR": cc, "CODEX_HOME": ch])
    check("CLAUDE_CONFIG_DIR is honoured", inst.claudeSettingsPath == cc + "/settings.json")
    check("CODEX_HOME is honoured", inst.codexHooksPath == ch + "/hooks.json")
    try! inst.installWithReport(claude: true, codex: true)
    check("files land in the env dirs, not under home", fm.fileExists(atPath: cc + "/settings.json") && fm.fileExists(atPath: ch + "/hooks.json") && !fm.fileExists(atPath: home.path + "/.claude") && !fm.fileExists(atPath: home.path + "/.codex"))
    check("~ in env var expands against the injected home", installer(home, env: ["CLAUDE_CONFIG_DIR": "~/cfg"]).claudeSettingsPath == home.path + "/cfg/settings.json")
    check("empty env var falls back to the default", installer(home, env: ["CLAUDE_CONFIG_DIR": "", "CODEX_HOME": ""]).claudeSettingsPath == home.path + "/.claude/settings.json")
    check("project-scope files are never referenced", !inst.claudeSettingsPath.contains("settings.local") )
}

func testStateTruthTable() {
    section("state() truth table")
    let (_, home) = newCase()
    let inst = installer(home)
    check("nothing on disk -> notInstalled", inst.state() == .notInstalled && inst.detailedState() == HooksDetailedState(claude: .notInstalled, codex: .notInstalled))
    write("{}", to: inst.claudeSettingsPath)
    check("settings.json = {} -> notInstalled", inst.detailedState().claude == .notInstalled)
    write(canonical(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo"}]}]}}"#), to: inst.claudeSettingsPath)
    check("only user hooks -> notInstalled", inst.detailedState().claude == .notInstalled)
    try! inst.installWithReport(claude: true, codex: false)
    check("claude only -> installed(claude: true, codex: false)", inst.state() == .installed(claude: true, codex: false))
    try! inst.installWithReport(claude: false, codex: true)
    check("both -> installed(true, true)", inst.state() == .installed(claude: true, codex: true))
    try! fm.removeItem(atPath: inst.claudeSettingsPath)
    check("claude file removed -> installed(claude: false, codex: true)", inst.state() == .installed(claude: false, codex: true))
    // partial: drop one event by hand
    try! inst.installWithReport(claude: true, codex: false)
    var obj = json(inst.claudeSettingsPath) as! [String: Any]
    var hk = obj["hooks"] as! [String: Any]; hk.removeValue(forKey: "Stop"); obj["hooks"] = hk
    try! JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: inst.claudeSettingsPath))
    check("one event missing -> partial(17 of 18)", inst.detailedState().claude == .partial(present: 17, expected: 18), "\(inst.detailedState().claude)")
    check("partial claude -> HooksState counts it as not installed for claude", inst.state() == .installed(claude: false, codex: true))
    try! inst.installWithReport(claude: true, codex: false)
    check("re-install heals a partial install", inst.detailedState().claude == .installed)
    // command edited by hand (exact match fails)
    var s = read(inst.claudeSettingsPath)!
    s = s.replacingOccurrences(of: "nc -w 1 -U", with: "nc -w 5 -U")
    write(s, to: inst.claudeSettingsPath)
    check("hand-edited command (not byte-exact) no longer counts: only the untouched PermissionRequest matches -> partial(1 of 18)", inst.detailedState().claude == .partial(present: 1, expected: 18), "\(inst.detailedState().claude)")
    write("{not json", to: inst.claudeSettingsPath)
    if case .unreadable = inst.detailedState().claude { check("unparseable file -> unreadable (tolerant, no throw)", true) } else { check("unparseable file -> unreadable (tolerant, no throw)", false) }
    check("unreadable -> HooksState says notInstalled for claude, codex still installed", inst.state() == .installed(claude: false, codex: true))
    try? fm.removeItem(atPath: inst.claudeSettingsPath)
    try! fm.createDirectory(atPath: inst.claudeSettingsPath, withIntermediateDirectories: true)
    if case .unreadable = inst.detailedState().claude { check("settings.json is a directory -> unreadable, no crash", true) } else { check("settings.json is a directory -> unreadable, no crash", false) }
}

func testPreview() {
    section("preview()")
    let (_, home) = newCase()
    let inst = installer(home)
    let listing0 = names(home.path)
    let p0 = inst.preview()
    check("preview of a fresh machine shows --- /dev/null and +++ new file", p0.contains("--- /dev/null") && p0.contains("(new file)"))
    check("preview lists every Claude event as an added line", claudeEntries.allSatisfy { p0.contains("\n+    \"\($0.event)\": [\n") })
    check("preview shows the exact command text (JSON-escaped)", p0.contains("\\\"agent\\\":\\\"claude\\\",\\\"ppid\\\":%s}") && p0.contains("/usr/bin/nc -w 1 -U"))
    check("preview has Claude and Codex sections", p0.contains("== Claude Code ==") && p0.contains("== Codex =="))
    check("preview mentions the Codex /hooks trust review", p0.contains("/hooks"))
    check("preview mentions the socket", p0.contains("$HOME/.atoll/run/agent.sock"))
    check("preview wrote nothing", names(home.path) == listing0 && !fm.fileExists(atPath: inst.claudeSettingsPath))
    check("preview(claude: true, codex: false) has no Codex section", !inst.preview(claude: true, codex: false).contains("== Codex =="))
    // existing file: real hunks with context
    write(canonical(userSettingsCompact), to: inst.claudeSettingsPath)
    let p1 = inst.preview(claude: true, codex: false)
    check("preview of an existing file has @@ hunks and unchanged context lines", p1.contains("\n@@ -") && p1.split(separator: "\n").contains { $0.hasPrefix(" ") } && p1.contains("\n+"))
    check("preview mentions the backup it would take", p1.contains("atoll-backup"))
    check("preview of existing file does not touch it", read(inst.claudeSettingsPath) == canonical(userSettingsCompact) && backups(of: inst.claudeSettingsPath).isEmpty)
    try! inst.installWithReport(claude: true, codex: true)
    let p2 = inst.preview()
    check("after install: preview says nothing to change", p2.contains("Nothing to change") && !p2.contains("@@"))
    check("after install: preview does not nag about Codex trust", !p2.contains("Note: Codex runs non-managed hooks"))

    section("HookDiff")
    check("identical text -> empty diff", HookDiff.unified(old: "a\nb\n", new: "a\nb\n", oldLabel: "x", newLabel: "y") == "")
    let d = HookDiff.unified(old: "a\nb\nc\nd\ne\nf\ng\nh\n", new: "a\nb\nc\nX\nd\ne\nf\ng\nh\n", oldLabel: "o", newLabel: "n")
    check("insert hunk header and lines", d.contains("@@ -1,6 +1,7 @@") && d.contains("+X") && d.contains(" c\n") && d.hasPrefix("--- o\n+++ n\n"), d)
    let d2 = HookDiff.unified(old: "", new: "a\nb\n", oldLabel: "/dev/null", newLabel: "n")
    check("diff from empty file", d2.contains("@@ -0,0 +1,2 @@") && d2.contains("+a\n+b"), d2)
    let d3 = HookDiff.unified(old: "a\nb\nc\n", new: "a\nB\nc\n", oldLabel: "o", newLabel: "n")
    check("replace shows - and +", d3.contains("-b\n+B\n"))
}

// MARK: - Running the generated hook command

func testHookExecution() {
    section("Hook command execution: fake server, missing socket, stale socket")
    let (dir, home) = newCase()
    let sockPath = home.path + "/.atoll/run/agent.sock"
    check("test socket path fits sun_path", sockPath.utf8.count < 104, "\(sockPath.utf8.count)")
    let payload = Data(#"{"session_id":"abc","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
    let me = getpid()

    func header(_ agent: String) -> Data { Data("{\"v\":1,\"agent\":\"\(agent)\",\"ppid\":\(me)}\n".utf8) }

    // 1. live server, non-blocking events
    do {
        let srv = FakeServer(path: sockPath, reply: "SHOULD-NOT-APPEAR")
        check("fake server starts", srv.start())
        for e in claudeEntries where !e.blocking {
            let r = runShell("/bin/sh", e.command, stdin: payload, home: home.path)
            check("claude \(e.event): exit 0, EMPTY stdout, empty stderr", r.status == 0 && r.out.isEmpty && r.err.isEmpty && !r.timedOut, "status=\(r.status) out=\(String(decoding: r.out, as: UTF8.self))")
        }
        Thread.sleep(forTimeInterval: 0.2)
        let got = srv.received
        check("server received one connection per non-blocking event", got.count == 17, "\(got.count)")
        check("wire format: header line then the raw hook JSON, byte-exact", got.first == header("claude") + payload, got.first.map { String(decoding: $0, as: UTF8.self) } ?? "nil")
        for e in codexEntries where !e.blocking { _ = runShell("/bin/sh", e.command, stdin: payload, home: home.path) }
        Thread.sleep(forTimeInterval: 0.2)
        check("codex header says agent=codex", srv.received.contains(header("codex") + payload))
        // other shells
        for sh in ["/bin/bash", "/bin/zsh"] where fm.fileExists(atPath: sh) {
            let r = runShell(sh, claudeNB, stdin: payload, home: home.path)
            check("works under \(sh) -c as well (exit 0, empty stdout)", r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        }
        // big payload
        let big = Data(repeating: 0x61, count: 300_000)
        let before = srv.received.count
        let rb = runShell("/bin/sh", claudeNB, stdin: big, home: home.path)
        Thread.sleep(forTimeInterval: 0.3)
        check("300 KB payload delivered intact", rb.status == 0 && srv.received.count == before + 1 && srv.received.last?.count == header("claude").count + big.count, "\(srv.received.last?.count ?? -1)")
        srv.stop()
    }
    // 2. PermissionRequest answered by the server
    do {
        let decision = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        let srv = FakeServer(path: sockPath, reply: decision)
        srv.start()
        let r = runShell("/bin/sh", claudePR, stdin: payload, home: home.path)
        check("PermissionRequest: server's decision passes through stdout verbatim", String(decoding: r.out, as: UTF8.self) == decision && r.status == 0, String(decoding: r.out, as: UTF8.self))
        check("PermissionRequest: stderr empty", r.err.isEmpty)
        let rc = runShell("/bin/sh", codexPR, stdin: payload, home: home.path)
        check("Codex PermissionRequest: decision passes through", String(decoding: rc.out, as: UTF8.self) == decision && rc.status == 0)
        srv.stop()
    }
    // 3. PermissionRequest where Atoll closes without a decision ("let the terminal decide")
    do {
        let srv = FakeServer(path: sockPath, reply: nil)
        srv.start()
        let r = runShell("/bin/sh", claudePR, stdin: payload, home: home.path)
        check("PermissionRequest closed without decision: exit 0, empty stdout", r.status == 0 && r.out.isEmpty && r.err.isEmpty && !r.timedOut)
        srv.stop()
    }
    // 4. server accepts and slams the door
    do {
        let srv = FakeServer(path: sockPath, closeWithoutReading: true)
        srv.start()
        let r = runShell("/bin/sh", claudePR, stdin: payload, home: home.path)
        let r2 = runShell("/bin/sh", claudeNB, stdin: payload, home: home.path)
        check("server closes immediately: blocking hook exit 0, empty stdout", r.status == 0 && r.out.isEmpty && !r.timedOut)
        check("server closes immediately: non-blocking hook exit 0, empty stdout", r2.status == 0 && r2.out.isEmpty && !r2.timedOut)
        srv.stop()
    }
    // 5. wedged server: non-blocking hook must give up (nc -w 1) well inside its 3 s timeout
    do {
        let srv = FakeServer(path: sockPath, reply: nil, holdOpenSeconds: 6)
        srv.start()
        let r = runShell("/bin/sh", claudeNB, stdin: payload, home: home.path, timeout: 10)
        check("wedged server: non-blocking hook returns in < 3 s (nc -w 1), exit 0, empty stdout", r.elapsed < 3.0 && r.status == 0 && r.out.isEmpty && !r.timedOut, "elapsed \(r.elapsed)")
        srv.stop()
    }
    // 6. missing socket
    do {
        try? fm.removeItem(atPath: sockPath)
        for e in [claudeEntries[0], claudeEntries.first { $0.blocking }!, codexEntries[0], codexEntries.first { $0.blocking }!] {
            let r = runShell("/bin/sh", e.command, stdin: payload, home: home.path)
            check("missing socket (\(e.event)\(e.blocking ? ", blocking" : "")): exit 0, empty stdout, empty stderr, fast", r.status == 0 && r.out.isEmpty && r.err.isEmpty && r.elapsed < 1.0, "elapsed \(r.elapsed)")
        }
        let r = runShell("/bin/sh", claudeNB, stdin: Data(), home: "/nonexistent-home-\(me)")
        check("HOME pointing nowhere: still exit 0, empty stdout", r.status == 0 && r.out.isEmpty && r.err.isEmpty)
    }
    // 7. stale socket file (bound, then closed: file remains, nobody listens)
    do {
        try? fm.removeItem(atPath: sockPath)
        try? fm.createDirectory(atPath: (sockPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        var (addr, len) = FakeServer.makeAddr(sockPath)!
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
        close(s)
        var st = stat()
        check("stale socket file exists and is a socket", lstat(sockPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK)
        for e in [claudeEntries[0], claudeEntries.first { $0.blocking }!, codexEntries[0], codexEntries.first { $0.blocking }!] {
            let r = runShell("/bin/sh", e.command, stdin: payload, home: home.path)
            check("stale socket (\(e.event)\(e.blocking ? ", blocking" : "")): exit 0, empty stdout, empty stderr", r.status == 0 && r.out.isEmpty && r.err.isEmpty && !r.timedOut, "status=\(r.status) err=\(String(decoding: r.err, as: UTF8.self))")
        }
        unlink(sockPath)
    }
    // 8. regular file / directory at the socket path
    do {
        write("not a socket", to: sockPath)
        let r = runShell("/bin/sh", claudePR, stdin: payload, home: home.path)
        check("regular file at the socket path: exit 0, empty stdout", r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        try? fm.removeItem(atPath: sockPath)
        try? fm.createDirectory(atPath: sockPath, withIntermediateDirectories: true)
        let r2 = runShell("/bin/sh", claudePR, stdin: payload, home: home.path)
        check("directory at the socket path: exit 0, empty stdout", r2.status == 0 && r2.out.isEmpty && r2.err.isEmpty)
        try? fm.removeItem(atPath: sockPath)
    }
    // 9. custom socket path, including a space in the path
    do {
        let custom = dir.path + "/my sock/a.sock"
        let entries = try! HookCommand.entries(for: .claudeCode, socketPath: custom)
        let srv = FakeServer(path: custom, reply: "x")
        check("custom-path server starts", srv.start())
        let r = runShell("/bin/sh", entries[0].command, stdin: payload, home: home.path)
        Thread.sleep(forTimeInterval: 0.2)
        check("custom socket path (with a space) works, empty stdout", r.status == 0 && r.out.isEmpty && srv.received.first == header("claude") + payload)
        srv.stop()
        let hostile = try! HookCommand.entries(for: .claudeCode, socketPath: dir.path + "/a$(touch pwned)`touch pwned2`\"x.sock")
        let rh = runShell("/bin/sh", hostile[0].command, stdin: payload, home: home.path)
        check("socket path with shell metacharacters cannot inject commands", rh.status == 0 && !fm.fileExists(atPath: dir.path + "/pwned") && !fm.fileExists(atPath: dir.path + "/pwned2") && !fm.fileExists(atPath: "pwned") && !fm.fileExists(atPath: "pwned2"))
    }
}

func testSchemaShape() {
    section("Output is valid JSON in the shape Claude Code / Codex accept")
    let claudeSchemaEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "UserPromptSubmit", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Elicitation", "ElicitationResult", "TeammateIdle", "TaskCompleted", "Setup", "InstructionsLoaded", "CwdChanged", "FileChanged", "ConfigChange", "WorktreeCreate", "WorktreeRemove", "SessionStart", "SessionEnd", "PostToolBatch", "TaskCreated", "PermissionDenied", "UserPromptExpansion", "MessageDisplay", "DirectoryAdded"]
    let codexEvents: Set<String> = ["SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact", "PostCompact", "UserPromptSubmit", "Stop", "Interrupt"]
    let handlerKeys: Set<String> = ["type", "command", "timeout", "async", "asyncRewake", "shell", "if", "statusMessage", "args"]   // published hookCommand schema, additionalProperties=false
    let (_, home) = newCase()
    let inst = installer(home)
    write(canonical(userSettingsCompact), to: inst.claudeSettingsPath)
    try! inst.installWithReport(claude: true, codex: true)
    for (label, path, events) in [("Claude", inst.claudeSettingsPath, claudeSchemaEvents), ("Codex", inst.codexHooksPath, codexEvents)] {
        let data = readData(path)!
        let top = try? JSONSerialization.jsonObject(with: data, options: [])
        check("\(label): strictly valid JSON (JSONSerialization, no fragments)", top is [String: Any])
        let hooks = (top as? [String: Any])?["hooks"] as? [String: Any] ?? [:]
        check("\(label): every event name is a real event", hooks.keys.allSatisfy { events.contains($0) }, "\(hooks.keys.filter { !events.contains($0) })")
        var groupsOK = true, handlersOK = true, timeoutsOK = true
        for (ev, v) in hooks {
            guard let groups = v as? [[String: Any]] else { groupsOK = false; continue }
            for g in groups {
                if !Set(g.keys).isSubset(of: ["matcher", "hooks"]) || g["hooks"] == nil { groupsOK = false }
                for h in (g["hooks"] as? [[String: Any]]) ?? [] {
                    let ours = (h["command"] as? String).map { HookCommand.looksLikeAtoll($0, agent: label == "Claude" ? .claudeCode : .codex) } ?? false
                    if ours {
                        if Set(h.keys) != ["type", "command", "timeout"] || h["type"] as? String != "command" { handlersOK = false }
                        let t = h["timeout"] as? Int ?? -1
                        if t <= 0 || (ev == "PermissionRequest" ? t != 900 : t > 3) { timeoutsOK = false }
                    } else if label == "Claude", !Set(h.keys).isSubset(of: handlerKeys.union(["url", "prompt"])) { handlersOK = false }
                }
            }
        }
        check("\(label): hooks.<Event>[] = {matcher?, hooks: [...]} and nothing else", groupsOK)
        check("\(label): Toplet handlers are exactly {type:'command', command, timeout}", handlersOK)
        check("\(label): timeouts are positive integers (seconds) within policy", timeoutsOK)
    }
    check("no extra marker key anywhere in Toplet's handlers (schema forbids additional properties)", !(read(inst.claudeSettingsPath) ?? "").contains("\"atoll\""))
}

// MARK: - Main

@main
enum HooksTests {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        print("Toplet hooks tests, temp dir: \(root)")
        check("test root is inside the temp dir (never the real home)", root.hasPrefix(NSTemporaryDirectory()) && !root.hasPrefix(NSHomeDirectory() + "/.claude") && !root.hasPrefix(NSHomeDirectory() + "/.codex"))
        testCommandStrings()
        testOrderedJSON()
        testClaudeFreshInstall()
        testClaudePreservation()
        testClaudeEdgeMerges()
        testClaudeRefusals()
        testHugeAndBackups()
        testWarnings()
        testCodex()
        testEnvironment()
        testStateTruthTable()
        testPreview()
        testHookExecution()
        testSchemaShape()
        // restore any permissions we changed so cleanup works
        _ = try? shell("chmod -R u+rwx '\(root)'")
        try? fm.removeItem(atPath: root)
        print("\n\(passed) checks passed, \(failed) failed")
        print(failed == 0 ? "ALL PASS" : "FAILURES")
        exit(failed == 0 ? 0 : 1)
    }

    static func shell(_ cmd: String) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
        try p.run(); p.waitUntilExit()
    }
}
