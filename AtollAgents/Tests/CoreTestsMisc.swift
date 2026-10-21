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

// MARK: Fakes for the jump / quick-task seams

final class FakeScripts: AppleScriptRunning {
    let ran = Atomic<[String]>([])
    var outcomes: [AppleScriptOutcome] = [.ok("ok")]
    func run(_ source: String) -> AppleScriptOutcome {
        ran.mutate { $0.append(source) }
        return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
    }
}
final class FakeOpener: URLOpening {
    let opened = Atomic<[URL]>([])
    var result = true
    func open(_ url: URL) -> Bool { opened.mutate { $0.append(url) }; return result }
}
final class FakeActivator: AppActivating {
    var running: Set<String>
    let activated = Atomic<[String]>([])
    init(running: Set<String> = []) { self.running = running }
    func activate(bundleID: String) -> Bool { activated.mutate { $0.append(bundleID) }; return running.contains(bundleID) }
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
}
final class FakeRunner: ProcessRunning {
    struct Call: Equatable { var exe: String; var args: [String]; var cwd: String? }
    let calls = Atomic<[Call]>([])
    var handler: (String, [String]) -> ProcessRunResult = { _, _ in ProcessRunResult(status: 0, stdout: "", stderr: "", timedOut: false, launchError: nil) }
    func run(executable: String, arguments: [String], cwd: String?, timeout: TimeInterval, maxOutput: Int) -> ProcessRunResult {
        calls.mutate { $0.append(Call(exe: executable, args: arguments, cwd: cwd)) }
        return handler(executable, arguments)
    }
}

/// Decodes an AppleScript string literal ("..." with \\ and \" escapes). nil when the literal is not well formed
/// (i.e. when something could terminate it early).
func parseASLiteral(_ s: String) -> String? {
    var it = Array(s)
    guard it.count >= 2, it.first == "\"", it.last == "\"" else { return nil }
    it.removeFirst(); it.removeLast()
    var out = ""
    var i = 0
    while i < it.count {
        let c = it[i]
        if c == "\\" { guard i + 1 < it.count, it[i + 1] == "\\" || it[i + 1] == "\"" else { return nil }; out.append(it[i + 1]); i += 2; continue }
        if c == "\"" { return nil }
        out.append(c); i += 1
    }
    return out
}

private func sess(_ jump: JumpTarget?, pid: Int32? = 4242, live: Bool = true, cwd: String = "/work/proj", tty: String? = "/dev/ttys004", host: String? = nil, title: String? = nil) -> AgentSession {
    var s = AgentSession(key: SessionKey(kind: .claudeCode, id: "j1"), cwd: cwd, status: .idle)
    s.jump = jump; s.pid = pid; s.isLive = live; s.tty = tty; s.hostAppBundleID = host; s.title = title
    return s
}

private func jumpAsync(_ j: TerminalJumper, _ s: AgentSession) async -> JumpResult {
    await withCheckedContinuation { cont in j.jump(to: s) { cont.resume(returning: $0) } }
}

private func sectionsFixture() -> [BoardSection] {
    let d = Date(timeIntervalSince1970: 1_790_000_000)
    return [
        BoardSection(title: "Ideas", tasks: [BoardTask(title: "Write docs", notes: "line1\nline2", isDone: false, createdAt: d), BoardTask(title: "Fix bug", isDone: true, createdAt: d, linkedSessionID: "claude:abc", agent: .claudeCode)]),
        BoardSection(title: "Later", tasks: [], isCollapsed: true),
    ]
}

func runMiscTests() async {
    section("BoardStore: persistence")
    do {
        let dir = makeTmp("bd")
        let url = URL(fileURLWithPath: dir + "/Toplet/agents-board.json")
        let store = BoardStore(url: url, debounce: 0.2)
        eq(store.load(), [], "missing file loads as an empty board")
        check(!store.lastLoadWasCorrupt, "a missing file is not corruption")
        let fx = sectionsFixture()
        store.scheduleSave(fx)
        store.flush()
        check(FileManager.default.fileExists(atPath: url.path), "flush writes the file (directory created)")
        eq(store.load(), fx, "round trip: sections, tasks, ids, dates, flags survive")
        let obj = jsonObject((try? String(contentsOfFile: url.path, encoding: .utf8)) ?? "")
        eq(obj?["version"] as? Int ?? 0, 1, "the file is versioned")
        eq(Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0), 0o600, "the board file is mode 0600")
        eq((try? FileManager.default.contentsOfDirectory(atPath: dir + "/Toplet")) ?? [], ["agents-board.json"], "atomic write leaves no temp files behind")
        // debounce
        let w0 = store.writeCount
        for i in 0..<10 { store.scheduleSave([BoardSection(title: "v\(i)")]) }
        eq(store.writeCount, w0, "debounced: nothing is written immediately")
        await sleepMs(500)
        eq(store.writeCount, w0 + 1, "debounced: ten rapid saves become one write")
        eq(store.load().first?.title ?? "", "v9", "debounced: the last value wins")
        store.scheduleSave([BoardSection(title: "pending")])
        store.flush()
        eq(store.load().first?.title ?? "", "pending", "flush() writes pending data immediately")
        let w1 = store.writeCount
        store.flush()
        eq(store.writeCount, w1, "flush() with nothing pending writes nothing")
    }

    section("BoardStore: corrupt and hostile files")
    do {
        func fresh(_ content: String?) -> (BoardStore, URL) {
            let u = URL(fileURLWithPath: makeTmp("bc") + "/b.json")
            if let c = content { write(u.path, c) }
            return (BoardStore(url: u, debounce: 0.05), u)
        }
        var (s, u) = fresh("this is not json {{{")
        eq(s.load(), [], "garbage file: empty board, no crash")
        check(s.lastLoadWasCorrupt, "garbage file: flagged as corrupt")
        eq((try? String(contentsOfFile: u.path + ".corrupt", encoding: .utf8)) ?? "", "this is not json {{{", "garbage file: a .corrupt copy is kept")
        let fixture = sectionsFixture()
        s.scheduleSave(fixture); s.flush()
        eq(s.load(), fixture, "after a corrupt load the store keeps working")
        check(FileManager.default.fileExists(atPath: u.path + ".corrupt"), "...and the .corrupt copy is still there")
        (s, u) = fresh("{\"version\":1,\"sections\":[")
        eq(s.load(), [], "truncated JSON: empty board"); check(s.lastLoadWasCorrupt, "truncated JSON: corrupt")
        (s, u) = fresh("[1,2,3]")
        eq(s.load(), [], "array root: empty board"); check(FileManager.default.fileExists(atPath: u.path + ".corrupt"), "array root: copy kept")
        (s, u) = fresh("{\"version\":99,\"sections\":[]}")
        eq(s.load(), [], "a newer file version is not interpreted"); check(FileManager.default.fileExists(atPath: u.path + ".corrupt"), "...and is preserved as a copy")
        (s, u) = fresh("{\"version\":0,\"sections\":[]}")
        eq(s.load(), [], "version 0: rejected")
        (s, u) = fresh("{\"sections\":[]}")
        eq(s.load(), [], "no version: rejected")
        let good = "{\"id\":\"11111111-1111-1111-1111-111111111111\",\"title\":\"Good\",\"tasks\":[],\"isCollapsed\":false}"
        (s, u) = fresh("{\"version\":1,\"sections\":[\(good),{\"id\":\"nope\",\"title\":5},42]}")
        let partial = s.load()
        eq(partial.count, 1, "a bad section is skipped, good ones survive"); eq(partial.first?.title ?? "", "Good", "...the good one is intact")
        check(FileManager.default.fileExists(atPath: u.path + ".corrupt"), "...and a copy of the original is kept")
        (s, u) = fresh("{\"version\":1,\"sections\":[{\"id\":\"22222222-2222-2222-2222-222222222222\",\"title\":\"T\",\"isCollapsed\":false,\"tasks\":[{\"id\":\"33333333-3333-3333-3333-333333333333\",\"title\":\"x\",\"notes\":\"\",\"isDone\":false,\"createdAt\":1790000000}]}]}")
        eq(s.load().first?.tasks.first?.title ?? "", "x", "numeric dates are tolerated")
        let (sBig, uBig) = fresh(nil)
        writeData(uBig.path, Data(repeating: 0x20, count: 9 << 20))
        eq(sBig.load(), [], "an oversized file is quarantined instead of parsed")
        let errs = Atomic<[String]>([])
        let bad = BoardStore(url: URL(fileURLWithPath: "/dev/null/nope/b.json"), debounce: 0.01)
        bad.onError = { m in errs.mutate { $0.append(m) } }
        bad.scheduleSave(sectionsFixture()); bad.flush()
        check(!errs.get().isEmpty, "a failing save reports an error instead of crashing")
    }

    section("BoardStore: bounds")
    do {
        let many = (0..<250).map { BoardSection(title: "S\($0)") }
        eq(BoardStore.sanitize(many).count, 200, "at most 200 sections")
        let perSection = (0..<5).map { s in BoardSection(title: "S\(s)", tasks: (0..<600).map { BoardTask(title: "t\(s)-\($0)") }) }
        eq(BoardStore.sanitize(perSection).reduce(0) { $0 + $1.tasks.count }, 2000, "at most 2000 tasks overall")
        let long = BoardSection(title: String(repeating: "T", count: 500), tasks: [BoardTask(title: String(repeating: "x", count: 900), notes: String(repeating: "n", count: 10_000))])
        let sl = BoardStore.sanitize([long])
        check(sl[0].title.count <= 200 && sl[0].tasks[0].title.count <= 200, "titles are at most 200 characters")
        check(sl[0].tasks[0].notes.count <= 4000, "notes are at most 4000 characters")
        let dirty = BoardStore.sanitize([BoardSection(title: "A\u{202E}B\u{0}\n", tasks: [BoardTask(title: "\u{200B}"), BoardTask(title: "ok", notes: "a\u{1B}[31m\nb")])])
        eq(dirty[0].title, "AB", "section titles are sanitised"); eq(dirty[0].tasks[0].title, "Untitled task", "an empty task title gets a placeholder")
        eq(dirty[0].tasks[1].notes, "a\nb", "notes keep newlines but lose control characters")
        eq(BoardStore.sanitize([BoardSection(title: " \u{200B} ")])[0].title, "Untitled", "an empty section title gets a placeholder")
        let dupID = UUID()
        eq(BoardStore.sanitize([BoardSection(id: dupID, title: "a"), BoardSection(id: dupID, title: "b")]).count, 1, "duplicate section ids are dropped")
        let tid = UUID()
        eq(BoardStore.sanitize([BoardSection(title: "a", tasks: [BoardTask(id: tid, title: "x"), BoardTask(id: tid, title: "y")])])[0].tasks.count, 1, "duplicate task ids are dropped")
    }

    section("TerminalJumper: AppleScript escaping and validation")
    do {
        let evil = "x\" & (do shell script \"touch /tmp/pwn\") & \"y\\\nz"
        let lit = AppleScriptEscaper.literal(evil)
        let decoded = parseASLiteral(lit)
        check(decoded != nil, "an injection attempt still produces a well-formed literal (no early termination)")
        eq(decoded ?? "", "x\" & (do shell script \"touch /tmp/pwn\") & \"y\\ z", "...which decodes back to the plain text (newline became a space)")
        eq(parseASLiteral(AppleScriptEscaper.literal("plain")) ?? "", "plain", "plain text round trip")
        eq(parseASLiteral(AppleScriptEscaper.literal("\u{0}\u{7}a")) ?? "", "  a", "control characters are neutralised")
        eq(parseASLiteral(AppleScriptEscaper.literal("back\\slash")) ?? "", "back\\slash", "backslashes are escaped")
        eq(parseASLiteral(AppleScriptEscaper.literal("\u{1F600} ünï")) ?? "", "\u{1F600} ünï", "unicode is preserved")
        check(AppleScriptEscaper.isValidTTY("/dev/ttys003"), "tty: /dev/ttys003 valid")
        check(!AppleScriptEscaper.isValidTTY("ttys003"), "tty: relative rejected")
        check(!AppleScriptEscaper.isValidTTY("/dev/ttys003\" & x & \""), "tty: injection rejected")
        check(!AppleScriptEscaper.isValidTTY("/dev/../etc/passwd"), "tty: traversal rejected")
        check(!AppleScriptEscaper.isValidTTY("/dev/ttys"), "tty: no digits rejected")
        check(!AppleScriptEscaper.isValidTTY("/dev/ttys003\n"), "tty: trailing newline rejected")
        check(TerminalJumper.script(bundleID: "com.apple.Terminal", tty: "/dev/ttys003\" & x", cwd: "/") == nil, "Terminal script refuses an invalid tty")
        check(TerminalJumper.script(bundleID: "com.apple.Terminal", tty: nil, cwd: "/") == nil, "Terminal script needs a tty")
        let ts = TerminalJumper.script(bundleID: "com.apple.Terminal", tty: "/dev/ttys003", cwd: "/") ?? ""
        check(ts.contains("tty of t is \"/dev/ttys003\"") && ts.contains("set selected tab of w to t"), "Terminal script matches the tab by tty")
        let it = TerminalJumper.script(bundleID: "com.googlecode.iterm2", tty: "/dev/ttys009", cwd: "/") ?? ""
        check(it.contains("tty of s is \"/dev/ttys009\"") && it.contains("select s"), "iTerm2 script matches the session by tty")
        let gs = TerminalJumper.script(bundleID: "com.mitchellh.ghostty", tty: nil, cwd: evil) ?? ""
        let marker = "working directory is "
        if let r = gs.range(of: marker), let end = gs[r.upperBound...].firstIndex(of: "\n") {
            eq(parseASLiteral(String(gs[r.upperBound..<end])) != nil, true, "Ghostty script: the cwd literal is well formed even for hostile input")
        } else { check(false, "Ghostty script shape") }
        check(!gs.contains("\ntouch") && gs.components(separatedBy: "\n").allSatisfy { !$0.contains("do shell script") || $0.contains("\\\"") }, "Ghostty script: hostile cwd cannot start a new statement")
        check(TerminalJumper.script(bundleID: "com.microsoft.VSCode", tty: "/dev/ttys001", cwd: "/") == nil, "VS Code has no per-tab script (activate only)")
        check(TerminalJumper.script(bundleID: "dev.warp.Warp-Stable", tty: "/dev/ttys001", cwd: "/") == nil, "Warp has no script (activate only)")
    }

    section("TerminalJumper: jump flows (fakes)")
    do {
        let scripts = FakeScripts(), opener = FakeOpener(), act = FakeActivator(running: ["com.apple.Terminal", "com.microsoft.VSCode", "com.googlecode.iterm2"])
        let runner = FakeRunner()
        let clock = Atomic(Date(timeIntervalSince1970: 1_800_000_000))
        let alive = Atomic<Set<Int32>>([4242])
        let j = TerminalJumper(scripts: scripts, opener: opener, activator: act, runner: runner, pidAlive: { p, _ in alive.get().contains(p) }, processCwd: { _ in "/work/proj" },
                               now: { clock.get() }, locateTmux: { "/fake/tmux" })
        var r = await jumpAsync(j, sess(.terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys004")))
        eq(r, .ok, "Terminal.app jump ok")
        check(scripts.ran.get().last?.contains("/dev/ttys004") == true, "...runs the tty script")
        scripts.outcomes = [.ok("notfound")]
        r = await jumpAsync(j, sess(.terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys004")))
        if case .failed(let m) = r { check(m.contains("activated"), "tab not found: falls back to activating the app") } else { check(false, "notfound should fail softly") }
        check(act.activated.get().contains("com.apple.Terminal"), "...and the terminal app was activated")
        r = await jumpAsync(j, sess(.terminal(bundleID: "com.googlecode.iterm2", tty: "/dev/ttys010")))
        eq(r, .failed("Could not find that session's tab in iTerm2; activated it instead."), "iTerm2 notfound message")
        // permission denied: one notice, never a prompt loop
        scripts.outcomes = [.notAuthorized]
        let n0 = scripts.ran.get().count
        r = await jumpAsync(j, sess(.terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys004")))
        if case .failed(let m) = r { check(m.contains("Automation"), "Automation denied: a clear notice that names the permission") } else { check(false, "denied should fail") }
        eq(scripts.ran.get().count, n0 + 1, "...the script ran once")
        r = await jumpAsync(j, sess(.terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys004")))
        eq(scripts.ran.get().count, n0 + 1, "a second attempt right after a denial does not run the script again (no prompt loop)")
        if case .failed = r { check(true, "...and still reports the problem") } else { check(false, "second attempt should still report") }
        clock.set(clock.get().addingTimeInterval(TerminalJumper.denialCooldown + 1))
        scripts.outcomes = [.ok("ok")]
        r = await jumpAsync(j, sess(.terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys004")))
        eq(r, .ok, "after the cooldown the script is tried again")
        scripts.outcomes = [.failed(-1728, "boom")]
        r = await jumpAsync(j, sess(.terminal(bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")))
        if case .failed = r { check(true, "an AppleScript error is a notice, not a crash") } else { check(false, "script error should fail") }
        r = await jumpAsync(j, sess(.terminal(bundleID: "com.mitchellh.ghostty", tty: nil)))
        eq(r, .failed("Ghostty is not running."), "terminal that is not running")
        // activation only
        r = await jumpAsync(j, sess(.app(bundleID: "com.microsoft.VSCode")))
        eq(r, .ok, "VS Code: activate only"); check(act.activated.get().last == "com.microsoft.VSCode", "...the app was activated")
        r = await jumpAsync(j, sess(.app(bundleID: "com.example.NotRunning")))
        if case .failed(let m) = r { check(m.contains("not running"), "app that is not running") } else { check(false, "not running should fail") }
        r = await jumpAsync(j, sess(nil, host: "com.microsoft.VSCode"))
        eq(r, .ok, "no jump target but a host app: activate it")
        r = await jumpAsync(j, sess(nil))
        if case .failed = r { check(true, "nothing known: a clear failure") } else { check(false, "should fail") }
        // deep link
        let url = URL(string: "codex://threads/0198aaaa-bbbb-7ccc-8ddd-eeeeffff0000")!
        r = await jumpAsync(j, sess(.deepLink(url), pid: nil))
        eq(r, .ok, "Codex deep link"); eq(opener.opened.get().last, url, "...opened through the URL opener")
        r = await jumpAsync(j, sess(.deepLink(URL(string: "https://evil.example/x")!), pid: nil))
        if case .failed = r { check(true, "non-codex deep links are refused") } else { check(false, "http link must be refused") }
        check(!opener.opened.get().contains(where: { $0.scheme == "https" }), "...and never opened")
        opener.result = false
        r = await jumpAsync(j, sess(.deepLink(url), pid: nil))
        if case .failed = r { check(true, "a failing open is reported") } else { check(false, "open failure should be reported") }
        // validation
        alive.set([])
        r = await jumpAsync(j, sess(.terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys004")))
        eq(r, .failed("That session has ended."), "dead pid: refused")
        alive.set([4242])
        let j2 = TerminalJumper(scripts: scripts, opener: opener, activator: act, runner: runner, pidAlive: { _, _ in true }, processCwd: { _ in "/somewhere/else" }, locateTmux: { "/fake/tmux" })
        r = await jumpAsync(j2, sess(.terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys004"), live: false))
        if case .failed(let m) = r { check(m.contains("no longer matches"), "passive session whose process cwd differs from the claim: refused") } else { check(false, "cwd mismatch should be refused") }
        scripts.outcomes = [.ok("ok")]
        r = await jumpAsync(j2, sess(.terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys004"), live: true))
        eq(r, .ok, "hook-live sessions may have `cd`-ed: the cwd check does not apply")

        // tmux: argument arrays, no shell
        runner.handler = { _, args in
            if args.first == "list-panes" { return ProcessRunResult(status: 0, stdout: "/dev/ttys004\twork\t1\t2\t999\n/dev/ttys005\tother\t3\t0\t998\n", stderr: "", timedOut: false, launchError: nil) }
            return ProcessRunResult(status: 0, stdout: "", stderr: "", timedOut: false, launchError: nil)
        }
        r = await jumpAsync(j, sess(.tmux(target: "work:1.2", clientBundleID: "com.apple.Terminal")))
        eq(r, .ok, "tmux jump ok")
        let calls = runner.calls.get()
        eq(calls.map { $0.args.first ?? "" }, ["list-panes", "switch-client", "select-window", "select-pane"], "tmux: list-panes, switch-client, select-window, select-pane")
        eq(calls.last?.args ?? [], ["select-pane", "-t", "work:1.2"], "tmux: select-pane targets session:window.pane")
        eq(calls[1].args, ["switch-client", "-t", "work"], "tmux: switch-client targets the session")
        check(calls.allSatisfy { $0.exe == "/fake/tmux" && !$0.args.contains("-c") && !$0.exe.hasSuffix("sh") }, "tmux: executed directly with argument arrays, never through a shell")
        check(act.activated.get().last == "com.apple.Terminal", "tmux: the hosting terminal is activated afterwards")
        runner.calls.set([])
        r = await jumpAsync(j, sess(.tmux(target: "gone:9.9", clientBundleID: nil), tty: "/dev/ttys777"))
        eq(r, .failed("That tmux pane no longer exists."), "tmux: a vanished pane is reported")
        let j3 = TerminalJumper(scripts: scripts, opener: opener, activator: act, runner: runner, pidAlive: { _, _ in true }, processCwd: { _ in "/work/proj" }, locateTmux: { nil })
        r = await jumpAsync(j3, sess(.tmux(target: "work:1.2", clientBundleID: nil)))
        eq(r, .failed("tmux was not found."), "tmux missing: a clear notice")
        eq(TmuxTool.parsePanes("/dev/ttys001\ta\t0\t0\t10\nbroken line\n/dev/ttys002\t-evil\t0\t0\t11\n/dev/ttys003\tb\tx\t0\t12\n").map { $0.target }, ["a:0.0"], "tmux parsePanes: malformed lines and option-like session names are dropped")
        eq(TmuxTool.jumpCommands(for: TmuxTool.Pane(tty: "t", target: "s:1.2", window: "s:1", session: "s", pid: 1)), [["switch-client", "-t", "s"], ["select-window", "-t", "s:1"], ["select-pane", "-t", "s:1.2"]], "tmux jumpCommands")
    }

    section("Source audit: no keystrokes, no Accessibility, no shell, no auto-approve flags")
    do {
        let coreDir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Core").path
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: coreDir)) ?? []).filter { $0.hasSuffix(".swift") }
        check(files.count >= 15, "audit sees the Core sources (\(files.count) files)")
        var all = ""
        var appKitFiles: [String] = []
        for f in files {
            let t = (try? String(contentsOfFile: coreDir + "/" + f, encoding: .utf8)) ?? ""
            all += t
            if t.contains("import AppKit") || t.contains("import SwiftUI") { appKitFiles.append(f) }
        }
        for banned in ["CGEvent", "AXUIElement", "AXIsProcessTrusted", "System Events", "dangerously-skip-permissions", "--yolo", "popen(", "system(", "fileURLWithPath: \"/bin/sh\"", "fileURLWithPath: \"/bin/bash\"", "fileURLWithPath: \"/bin/zsh\"", "fileURLWithPath: \"/usr/bin/env\"", "NWListener", "SwiftUI"] {
            check(!all.contains(banned), "Core never uses \(banned)")
        }
        check(Set(appKitFiles).isSubset(of: ["TerminalJumper.swift"]), "AppKit is confined to TerminalJumper.swift (found in: \(appKitFiles))")
        check(all.contains("umask(0o177)") && all.contains("S_IFSOCK"), "socket server sets umask 0177 and checks the file type")
    }

    section("QuickTaskRunner")
    do {
        eq(QuickTaskRunner.claudeArguments(prompt: "fix the bug"), ["--bg", "fix the bug"], "claude args: exactly --bg <title>")
        eq(QuickTaskRunner.claudeArguments(prompt: "-rf everything"), ["--bg", "Task: -rf everything"], "a leading dash cannot become an option")
        for p in ["do it", "--dangerously-skip-permissions", "x"] { check(!QuickTaskRunner.claudeArguments(prompt: p).dropFirst(1).contains("--dangerously-skip-permissions") || p.hasPrefix("--"), "no auto-approve flag is added (\(p.prefix(8)))") }
        let u = QuickTaskRunner.codexURL(prompt: "fix a&b=c +d #e ünï \u{1F600}", cwd: "/Users/me/My Project")!
        check(u.absoluteString.hasPrefix("codex://threads/new?prompt="), "codex url scheme and path")
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        eq(comps?.queryItems?.first(where: { $0.name == "prompt" })?.value ?? "", "fix a&b=c +d #e ünï \u{1F600}", "codex url: prompt survives percent-encoding exactly")
        eq(comps?.queryItems?.first(where: { $0.name == "path" })?.value ?? "", "/Users/me/My Project", "codex url: path survives percent-encoding")
        check(!u.absoluteString.contains(" ") && !u.absoluteString.contains("#") , "codex url has no raw spaces or fragments")
        eq(QuickTaskRunner.extractSessionID(from: "Started 0198AAAA-bbbb-7ccc-8ddd-eeeeffff0001 ok") ?? "nil", "0198aaaa-bbbb-7ccc-8ddd-eeeeffff0001", "extract a session id from output")
        check(QuickTaskRunner.extractSessionID(from: "no id here") == nil, "no id: nil (never invented)")
        check(QuickTaskRunner.prompt(from: String(repeating: "p", count: 5000)).count <= QuickTaskRunner.maxPromptLength, "prompt is bounded")

        let work = makeTmp("qt")
        let runner = FakeRunner()
        runner.handler = { _, _ in ProcessRunResult(status: 0, stdout: "Background session started: 0198aaaa-bbbb-7ccc-8ddd-eeeeffff0001\n", stderr: "", timedOut: false, launchError: nil) }
        let opener = FakeOpener()
        let q = QuickTaskRunner(runner: runner, opener: opener, locateClaude: { "/fake/bin/claude" })
        func run(_ q: QuickTaskRunner, title: String, agent: AgentKind, cwd: String) async -> (QuickTaskRunner.Outcome, Bool) {
            await withCheckedContinuation { cont in q.start(title: title, agent: agent, cwd: URL(fileURLWithPath: cwd, isDirectory: true)) { cont.resume(returning: ($0, Thread.isMainThread)) } }
        }
        var (o, main) = await run(q, title: "Refactor the parser", agent: .claudeCode, cwd: work)
        eq(o.kind, .started, "claude: started"); eq(o.sessionID ?? "", "claude:0198aaaa-bbbb-7ccc-8ddd-eeeeffff0001", "claude: id linked from the output"); check(main, "claude: completion on the main thread")
        eq(runner.calls.get().last, FakeRunner.Call(exe: "/fake/bin/claude", args: ["--bg", "Refactor the parser"], cwd: work), "claude: argument array, in the task's cwd, no shell")
        runner.handler = { _, _ in ProcessRunResult(status: 0, stdout: "started\n", stderr: "", timedOut: false, launchError: nil) }
        (o, _) = await run(q, title: "t", agent: .claudeCode, cwd: work)
        check(o.kind == .started && o.sessionID == nil, "claude: no id in the output means no link (not invented)")
        runner.handler = { _, _ in ProcessRunResult(status: 2, stdout: "", stderr: "workspace not trusted\n", timedOut: false, launchError: nil) }
        (o, _) = await run(q, title: "t", agent: .claudeCode, cwd: work)
        check(o.kind == .failed && o.message.contains("not trusted"), "claude: failure message carries stderr")
        runner.handler = { _, _ in ProcessRunResult(status: -1, stdout: "", stderr: "", timedOut: true, launchError: nil) }
        (o, _) = await run(q, title: "t", agent: .claudeCode, cwd: work)
        check(o.kind == .failed && o.message.contains("in time"), "claude: timeout reported")
        runner.handler = { _, _ in ProcessRunResult(status: -1, stdout: "", stderr: "", timedOut: false, launchError: "no such file") }
        (o, _) = await run(q, title: "t", agent: .claudeCode, cwd: work)
        check(o.kind == .failed, "claude: launch error reported")
        let missing = QuickTaskRunner(runner: runner, opener: opener, locateClaude: { nil })
        (o, _) = await run(missing, title: "t", agent: .claudeCode, cwd: work)
        check(o.kind == .failed && o.message.contains("claude"), "claude missing from PATH: a clear message")
        (o, _) = await run(q, title: "t", agent: .claudeCode, cwd: work + "/nope")
        check(o.kind == .failed && o.message.contains("does not exist"), "nonexistent cwd: refused")
        (o, _) = await run(q, title: "  \u{200B} ", agent: .claudeCode, cwd: work)
        check(o.kind == .failed, "empty title: refused")
        let before = runner.calls.get().count
        (o, main) = await run(q, title: "Write the changelog", agent: .codex, cwd: work)
        eq(o.kind, .opened, "codex: opened"); check(main, "codex: completion on the main thread")
        eq(runner.calls.get().count, before, "codex: nothing is spawned")
        let opened = opener.opened.get().last
        check(opened?.scheme == "codex" && opened?.absoluteString.contains("prompt=Write%20the%20changelog") == true, "codex: deep link with the encoded prompt")
        opener.result = false
        (o, _) = await run(q, title: "x", agent: .codex, cwd: work)
        check(o.kind == .failed, "codex: open failure reported")

        // Real runner: end to end with a fake `claude` script found through the locator
        let bin = makeTmp("bin")
        write(bin + "/claude", "#!/bin/sh\necho \"args: $@\"\npwd\necho 0198aaaa-bbbb-7ccc-8ddd-eeeeffff0002\n")
        chmod(bin + "/claude", 0o755)
        write(bin + "/notexec", "x")
        check(ExecutableLocator.find("claude", dirs: [bin]) == bin + "/claude", "locator: finds an executable in the given dirs")
        check(ExecutableLocator.find("notexec", dirs: [bin]) == nil, "locator: skips non-executable files")
        check(ExecutableLocator.find("../claude", dirs: [bin]) == nil && ExecutableLocator.find("a/b", dirs: [bin]) == nil, "locator: names with slashes are rejected")
        check(ExecutableLocator.find("claude", dirs: ["/nonexistent", bin]) == bin + "/claude", "locator: later dirs are searched")
        check(ExecutableLocator.searchDirs(home: "/h", path: "/usr/bin").contains("/h/.local/bin") && ExecutableLocator.searchDirs(home: "/h", path: "/usr/bin").contains("/opt/homebrew/bin"), "locator: adds ~/.local/bin and Homebrew to a GUI app's minimal PATH")
        let real = QuickTaskRunner(runner: SystemProcessRunner(), opener: opener, locateClaude: { ExecutableLocator.find("claude", dirs: [bin]) })
        (o, _) = await run(real, title: "do the thing", agent: .claudeCode, cwd: work)
        eq(o.kind, .started, "real runner: fake claude started")
        eq(o.sessionID ?? "", "claude:0198aaaa-bbbb-7ccc-8ddd-eeeeffff0002", "real runner: id parsed from real output")
        check(o.output.contains("--bg do the thing"), "real runner: the exact arguments reached the process")
        check(o.output.contains((work as NSString).resolvingSymlinksInPath), "real runner: the process ran in the task's cwd")
        let rr = SystemProcessRunner()
        let ys = rr.run(executable: "/usr/bin/yes", arguments: [], cwd: nil, timeout: 0.4, maxOutput: 1000)
        check(ys.timedOut && ys.stdout.count <= 1000, "runner: output is bounded and runaway processes are killed (\(ys.stdout.count) bytes)")
        eq(rr.run(executable: "/bin/echo", arguments: ["a b", "c"], cwd: nil, timeout: 5, maxOutput: 100).stdout, "a b c\n", "runner: arguments are passed verbatim")
        eq(rr.run(executable: "/usr/bin/false", arguments: [], cwd: nil, timeout: 5, maxOutput: 100).status, 1, "runner: exit status")
        check(rr.run(executable: "/nonexistent/prog", arguments: [], cwd: nil, timeout: 5, maxOutput: 100).launchError != nil, "runner: launch failure reported")
        check(rr.run(executable: "/bin/pwd", arguments: [], cwd: work, timeout: 5, maxOutput: 200).stdout.contains((work as NSString).resolvingSymlinksInPath), "runner: cwd honoured")
    }

    section("HookInstalling: read-only marker check and plug-in point")
    do {
        let base = makeTmp("hk")
        let insp = HookMarkerInspector(claudeDir: base + "/claude", codexDir: base + "/codex")
        eq(insp.state(), .notInstalled, "no files: not installed")
        write(base + "/claude/settings.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"S=\\\"$HOME/.atoll/run/agent.sock\\\"; exit 0\"}]}]}}")
        eq(insp.state(), .installed(claude: true, codex: false), "Claude settings with Toplet's marker")
        write(base + "/codex/hooks.json", "{\"x\":\"atoll-agent-hook\"}")
        eq(insp.state(), .installed(claude: true, codex: true), "Codex hooks.json with Toplet's marker")
        write(base + "/claude/settings.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo someone else\"}]}]}}")
        write(base + "/codex/hooks.json", "{}")
        eq(insp.state(), .notInstalled, "other tools' hooks are not mistaken for Toplet's")
        write(base + "/codex/config.toml", "[[hooks.Stop]]\ncommand = \"~/.atoll/run/agent.sock\"")
        eq(insp.state(), .installed(claude: false, codex: true), "Codex config.toml with the marker")
        write(base + "/claude/settings.json", "not even json .atoll/run/agent.sock")
        check(insp.claudeInstalled(), "a malformed file is still scanned textually and never throws")
        let noop = NoopHookInstaller(inspector: insp)
        eq(noop.preview(), "", "no-op installer: empty preview")
        do { try noop.install(claude: true, codex: true); try noop.uninstall(); check(true, "no-op installer: install/uninstall succeed without touching anything") } catch { check(false, "no-op threw") }
        eq(NoopHookInstaller(inspector: insp).state(), insp.state(), "no-op installer reports the inspector's state")
        eq((try? String(contentsOfFile: base + "/claude/settings.json", encoding: .utf8)) ?? "", "not even json .atoll/run/agent.sock", "inspection never modifies files")
    }
}
