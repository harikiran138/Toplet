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

// The REAL scripts/atoll-notify (POSIX sh, real /usr/bin/nc) against a fake server (raw payload capture) and against the real ingress server.
// Hostile arguments in every position must be inert: escaped, delivered as data, never executed.

private let hostile: [String] = {
    var allCtrl = ""
    for v in 1...31 { allCtrl += String(UnicodeScalar(UInt8(v))) }
    allCtrl += "\u{7F}"
    let abs = "\(testRoot)/PWN"
    return [
        "$(touch \(abs)1)",
        "`touch \(abs)2`",
        "\"; touch \(abs)3; \"",
        "'; touch \(abs)4 #",
        "line1\nline2\nline3",
        "quote\" backslash\\ both\\\" end\\",
        "tab\there\rcarriage",
        "ctrl[" + allCtrl + "]",
        "unicode \u{00E9} \u{65E5}\u{672C}\u{8A9E} \u{1F600} \u{202E}rtl\u{202C}",
        "--help",
        "-t",
        "%s%n%x %d \\n \\u0041",
        "* ~ $HOME ${IFS} $((1+1)) !! & | > < ;",
        "\",\"v\":2,\"priority\":\"critical\",\"x\":\"",
        "{} [] null true",
        "'",
        "\\\\\\",
        "touch PWNREL; echo",
        String(repeating: "a", count: 3000),
    ]
}()

private let fieldFlags: [(flag: String, key: String)] = [
    ("-t", "title"), ("-b", "body"), ("-s", "subtitle"), ("-a", "app"), ("-i", "bundleID"), ("--symbol", "symbol"),
    ("-u", "url"), ("-o", "openApp"), ("--tab", "tab"), ("--dedupe", "dedupe"), ("--thread", "thread"),
]

func runScriptTests() async {
    guard let script = ProcessInfo.processInfo.environment["AN_NOTIFY_SCRIPT"], FileManager.default.fileExists(atPath: script) else {
        check(false, "AN_NOTIFY_SCRIPT must point at scripts/atoll-notify (run through run_queue.sh)")
        return
    }
    let home = makeTmp("home")
    let cwdBefore = FileManager.default.currentDirectoryPath

    func run(_ args: [String], sock: String?, stdin: String = "", shell: String? = nil, env: [String: String] = [:]) async -> ShellResult {
        var e: [String: String] = ["HOME": home]
        if let s = sock { e["ATOLL_NOTIFY_SOCKET"] = s } else { e["ATOLL_NOTIFY_SOCKET"] = home + "/none.sock" }
        for (k, v) in env { e[k] = v }
        if let sh = shell { return await runProcess(sh, [script] + args, stdin: Data(stdin.utf8), env: e) }
        return await runProcess(script, args, stdin: Data(stdin.utf8), env: e)
    }

    section("atoll-notify: file and interface")
    check(access(script, X_OK) == 0, "script is executable")
    let text = (try? String(contentsOfFile: script, encoding: .utf8)) ?? ""
    let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
    check(text.hasPrefix("#!/bin/sh\n"), "POSIX sh shebang")
    check(!code.contains("python") && !code.contains("perl") && !code.contains("osascript") && !code.contains("curl"), "no python/perl/osascript/curl in the executable lines")
    check(code.range(of: "\\beval\\b", options: .regularExpression) == nil && code.range(of: "\\bsource\\b", options: .regularExpression) == nil, "no eval and no source anywhere in the code")
    check(code.contains("/usr/bin/nc"), "uses the absolute path /usr/bin/nc")
    let help = await run(["--help"], sock: nil)
    check(help.status == 0 && help.stdout.contains("usage: atoll-notify") && help.stdout.contains("--strict") && help.stdout.contains("--sensitive"), "--help exits 0 and prints usage")
    let h2 = await run(["-h"], sock: nil)
    eq(h2.stdout, help.stdout, "-h is the same as --help")
    let ver = await run(["--version"], sock: nil)
    check(ver.status == 0 && ver.stdout.hasPrefix("atoll-notify"), "--version")

    guard let fake = FakeSocketServer(dir: makeTmp("fk")) else { check(false, "fake server could not start"); return }
    defer { fake.stop() }

    section("atoll-notify: well-formed requests (fake server captures the exact bytes)")
    do {
        let r = await run(["-t", "Hello"], sock: fake.path)
        check(r.status == 0 && r.stdout.isEmpty && r.stderr.isEmpty, "-t only: exit 0, silent")
        let p = fake.payloads.last.flatMap(jsonObject)
        check(p?["v"] as? Int == 1 && p?["title"] as? String == "Hello" && p?.count == 2, "-t only: exactly {v:1,title}")
        let raw = String(decoding: fake.payloads.last ?? Data(), as: UTF8.self)
        eq(raw, "{\"v\":1,\"title\":\"Hello\"}", "wire bytes are compact JSON with no trailing newline")
    }
    do {
        let r = await run(["-t", "T", "-b", "B", "-s", "S", "-a", "A", "-i", "com.apple.Terminal", "--symbol", "hammer.fill", "-u", "https://example.com/x?y=1",
                           "-p", "high", "--ttl", "5", "--dedupe", "d", "--thread", "th", "--sensitive"], sock: fake.path)
        let p = fake.payloads.last.flatMap(jsonObject)
        eq(r.status, 0, "all options: exit 0")
        check(p?["body"] as? String == "B" && p?["subtitle"] as? String == "S" && p?["app"] as? String == "A", "body, subtitle, app")
        check(p?["bundleID"] as? String == "com.apple.Terminal" && p?["symbol"] as? String == "hammer.fill" && p?["url"] as? String == "https://example.com/x?y=1", "bundleID, symbol, url")
        check(p?["priority"] as? String == "high" && (p?["ttl"] as? NSNumber)?.doubleValue == 5 && p?["dedupe"] as? String == "d" && p?["thread"] as? String == "th", "priority, ttl, dedupe, thread")
        check(p?["sensitive"] as? Bool == true, "--sensitive sets sensitive:true")
        _ = await run(["-t", "T"], sock: fake.path)
        check(fake.payloads.last.flatMap(jsonObject)?["sensitive"] == nil, "sensitive is absent unless asked for")
        _ = await run(["-t", "T", "-o", "com.apple.Terminal"], sock: fake.path)
        eq(fake.payloads.last.flatMap(jsonObject)?["openApp"] as? String ?? "", "com.apple.Terminal", "-o sends openApp")
        _ = await run(["-t", "T", "--tab", "agents"], sock: fake.path)
        eq(fake.payloads.last.flatMap(jsonObject)?["tab"] as? String ?? "", "agents", "--tab sends tab")
        _ = await run(["--title=Long", "--body=Form", "--priority=low", "--ttl=2.5", "--bundle-id=com.a.b", "--open-app=com.c.d", "--subtitle=sub", "--app=ap", "--url=https://a.b", "--dedupe=k", "--thread=t"], sock: fake.path)
        let q = fake.payloads.last.flatMap(jsonObject)
        check(q?["title"] as? String == "Long" && q?["body"] as? String == "Form" && q?["priority"] as? String == "low" && (q?["ttl"] as? NSNumber)?.doubleValue == 2.5, "--option=value forms")
        for p in ["low", "normal", "high", "critical"] {
            let rr = await run(["-t", "T", "-p", p], sock: fake.path)
            check(rr.status == 0 && fake.payloads.last.flatMap(jsonObject)?["priority"] as? String == p, "priority \(p) accepted")
        }
        let b = await run(["-t", "T", "-b", "-"], sock: fake.path, stdin: "from stdin\nsecond line\n")
        eq(fake.payloads.last.flatMap(jsonObject)?["body"] as? String ?? "", "from stdin\nsecond line", "-b - reads the body from stdin")
        _ = b
        let e1 = await run(["-t", "--help"], sock: fake.path)
        check(e1.status == 0 && fake.payloads.last.flatMap(jsonObject)?["title"] as? String == "--help", "an option-looking value is data: -t --help sends the title \"--help\"")
        _ = await run(["-t", "x", "-b", "-t"], sock: fake.path)
        eq(fake.payloads.last.flatMap(jsonObject)?["body"] as? String ?? "", "-t", "a value of -t after -b is the body, not an option")
        let em = await run(["-t", "x", "-b", ""], sock: fake.path)
        check(em.status == 0 && fake.payloads.last.flatMap(jsonObject)?["body"] == nil, "an empty value is omitted")
        _ = await run(["-t", "x", "--socket", fake.path], sock: home + "/other.sock")
        check(fake.payloads.last.flatMap(jsonObject)?["title"] as? String == "x", "--socket overrides ATOLL_NOTIFY_SOCKET")
    }

    section("atoll-notify: ttl and priority validation")
    do {
        let before = fake.payloads.count
        for (name, v) in [("007.50", "007.50"), ("5", "5"), ("0.5", "0.5"), ("00", "00")] {
            let r = await run(["-t", "T", "--ttl", v], sock: fake.path)
            if name == "00" { continue }
            let n = (fake.payloads.last.flatMap(jsonObject)?["ttl"] as? NSNumber)?.doubleValue
            check(r.status == 0 && n == Double(v), "ttl \(name) is sent as a valid JSON number (\(n ?? -1))")
        }
        let afterOK = fake.payloads.count
        for v in [".5", "5.", "1e5", "-1", "1.2.3", "abc", "5 ", "1;ls", "$(id)", "0x10"] {
            let r = await run(["-t", "T", "--ttl", v], sock: fake.path)
            check(r.status == 2 && r.stdout.isEmpty && !r.stderr.isEmpty, "ttl \(v.debugDescription) is a usage error (exit 2)")
        }
        eq(fake.payloads.count, afterOK, "...and nothing was sent")
        for v in ["urgent", "HIGH", "high; ls", "", "1", "$(id)"] where !v.isEmpty {
            let r = await run(["-t", "T", "-p", v], sock: fake.path)
            check(r.status == 2, "priority \(v.debugDescription) is a usage error")
        }
        _ = before
    }

    section("atoll-notify: usage errors send nothing")
    do {
        let n0 = fake.payloads.count
        for (name, args) in [("no arguments", [String]()), ("no title", ["-b", "x"]), ("unknown option", ["-t", "x", "--bogus"]), ("missing value", ["-t"]),
                             ("missing value for body", ["-t", "x", "-b"]), ("stray positional", ["-t", "x", "foo"]), ("after --", ["-t", "x", "--", "y"]),
                             ("short unknown", ["-z"]), ("empty title", ["-t", ""])] {
            let r = await run(args, sock: fake.path)
            check(r.status == 2 && r.stdout.isEmpty && r.stderr.contains("atoll-notify:"), "\(name): exit 2 with a message on stderr")
        }
        eq(fake.payloads.count, n0, "none of the usage errors connected to the socket")
        let ok = await run(["-t", "x", "--"], sock: fake.path)
        eq(ok.status, 0, "-- at the end is accepted")
    }

    section("atoll-notify: hostile arguments are inert")
    do {
        FileManager.default.createFile(atPath: "\(testRoot)/canary", contents: Data())
        var badRounds = 0
        for r in 0..<hostile.count {
            var args: [String] = []
            var expect: [String: String] = [:]
            for (i, f) in fieldFlags.enumerated() {
                let v = hostile[(r + i) % hostile.count]
                args += [f.flag, v]
                expect[f.key] = v
            }
            let res = await run(args, sock: fake.path)
            let p = fake.payloads.last.flatMap(jsonObject)
            var mismatches: [String] = []
            if res.status != 0 { mismatches.append("exit \(res.status)") }
            for (k, v) in expect {
                let sent = p?[k] as? String
                // The script caps each text field at 8192 bytes; no hostile string here is that long.
                if sent != v { mismatches.append("\(k): \(String((sent ?? "nil").prefix(30)).debugDescription)") }
            }
            if p?["v"] as? Int != 1 { mismatches.append("v changed") }
            if p?["priority"] != nil || p?["x"] != nil || p?["sensitive"] != nil || p?["ttl"] != nil { mismatches.append("an injected key appeared") }
            if (p?.count ?? 0) != 12 { mismatches.append("key count \(p?.count ?? -1)") }
            if !mismatches.isEmpty { badRounds += 1 }
            check(mismatches.isEmpty, "hostile round \(r + 1)/\(hostile.count): every field delivered verbatim as data \(mismatches.isEmpty ? "" : String(describing: mismatches))")
        }
        eq(badRounds, 0, "no hostile round altered any field")
        let leftovers = (1...4).filter { FileManager.default.fileExists(atPath: "\(testRoot)/PWN\($0)") }
        check(leftovers.isEmpty, "no injected command ran (absolute-path canaries absent)")
        check(!FileManager.default.fileExists(atPath: cwdBefore + "/PWNREL") && !FileManager.default.fileExists(atPath: "PWNREL"), "no injected command ran (relative canary absent)")
        for f in fieldFlags where f.flag != "-t" {
            // single hostile value in each position with a plain title, same checks
            let v = hostile[0]
            _ = await run(["-t", "plain", f.flag, v], sock: fake.path)
            check(fake.payloads.last.flatMap(jsonObject)?[f.key] as? String == v, "\(f.flag): \(f.key) carries the \"$(...)\" string literally")
        }
        let dashRes = FileManager.default.fileExists(atPath: "/bin/dash")
        if dashRes {
            var args: [String] = []
            for (i, f) in fieldFlags.enumerated() { args += [f.flag, hostile[(i + 7) % hostile.count]] }
            let d = await run(args, sock: fake.path, shell: "/bin/dash")
            let p = fake.payloads.last.flatMap(jsonObject)
            var ok = d.status == 0
            for (i, f) in fieldFlags.enumerated() where p?[f.key] as? String != hostile[(i + 7) % hostile.count] { ok = false }
            check(ok, "the same hostile round under /bin/dash (strict POSIX sh) delivers every field verbatim")
        }
        let bsh = await run(["-t", hostile[7]], sock: fake.path, shell: "/bin/bash")
        check(bsh.status == 0 && fake.payloads.last.flatMap(jsonObject)?["title"] as? String == hostile[7], "all control characters survive under bash too")
        let sensitive = await run(["-t", "$(echo pwn)", "--sensitive"], sock: fake.path)
        check(sensitive.status == 0 && fake.payloads.last.flatMap(jsonObject)?["title"] as? String == "$(echo pwn)", "the \"$(echo pwn)\" title is delivered, not expanded")
        check(!(await run(["-t", "x", "--socket", "/tmp/$(id)/x"], sock: nil)).stderr.contains("uid="), "a hostile --socket path is never expanded")
    }
    do {
        let big = String(repeating: "x", count: 100_000)
        let t = Date()
        let r = await run(["-t", big, "-b", String(repeating: "\u{65E5}", count: 20_000)], sock: fake.path)
        let dt = Date().timeIntervalSince(t)
        // The script cuts at a byte count, which can split a multi-byte character: the server repairs invalid UTF-8, so repair the same way here.
        let p = fake.payloads.last.flatMap { jsonObject(String(decoding: $0, as: UTF8.self)) }
        check(r.status == 0 && p != nil, "100 KB arguments: still valid JSON (after the server's UTF-8 repair), exit 0")
        check((p?["body"] as? String)?.isEmpty == false, "...the body survived the cut")
        check((p?["title"] as? String)?.count ?? 0 <= 8192, "...title capped by the script at 8192 bytes")
        check(dt < 4, "...in bounded time (\(String(format: "%.2f", dt)) s)")
    }
    do {  // PATH hijack: a fake nc earlier in PATH must never run
        let evil = makeTmp("evil")
        write(evil + "/nc", "#!/bin/sh\ntouch \(evil)/nc-ran\ncat >/dev/null\n")
        chmod(evil + "/nc", 0o755)
        write(evil + "/head", "#!/bin/sh\ntouch \(evil)/head-ran\n")
        chmod(evil + "/head", 0o755)
        let r = await run(["-t", "pathtest", "-b", "-"], sock: fake.path, stdin: "body", env: ["PATH": evil + ":/usr/bin:/bin"])
        check(r.status == 0 && fake.payloads.last.flatMap(jsonObject)?["title"] as? String == "pathtest", "a hostile PATH does not stop the script")
        check(!FileManager.default.fileExists(atPath: evil + "/nc-ran") && !FileManager.default.fileExists(atPath: evil + "/head-ran"), "...and no program from the hostile PATH was executed")
        let r2 = await run(["-t", "nopath"], sock: fake.path, env: ["PATH": "/nonexistent"])
        check(r2.status == 0 && fake.payloads.last.flatMap(jsonObject)?["title"] as? String == "nopath", "an empty PATH does not stop the script")
    }

    section("atoll-notify: Toplet not running, rejections, odd servers")
    do {
        let none = home + "/missing.sock"
        let r = await run(["-t", "x"], sock: none)
        check(r.status == 0 && r.stdout.isEmpty, "not running: exit 0, silent stdout")
        check(r.stderr.contains("not running") && r.stderr.filter { $0 == "\n" }.count == 1, "not running: a one-line hint on stderr")
        let rs = await run(["-t", "x", "--strict"], sock: none)
        check(rs.status == 3 && rs.stderr.contains("not running"), "--strict: exit 3 when Toplet is not running")
        let rp = await run(["-t", "x"], sock: "")
        check(rp.status == 0 && rp.stderr.contains("not running"), "with ATOLL_NOTIFY_SOCKET empty the default path under HOME (a temp HOME here, never the real ~/.atoll) is used")
        // stale socket file with no listener
        let stale = home + "/stale.sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var (a, l) = NotificationIngressServer.makeAddress(stale)!
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, l) } }
        close(fd)
        let r3 = await run(["-t", "x"], sock: stale)
        check(r3.status == 0 && r3.stderr.contains("not running"), "a stale socket file (nobody listening): exit 0 with the hint")
        let r4 = await run(["-t", "x", "--strict"], sock: stale)
        eq(r4.status, 3, "a stale socket file with --strict: exit 3")
        let rpath = await run(["-t", "x"], sock: "/tmp")
        check(rpath.status == 0 && rpath.stderr.contains("not running"), "a path that is not a socket is treated as not running")
    }
    do {
        fake.reply = Data("{\"ok\":false,\"error\":\"invalid url\"}\n".utf8)
        let r = await run(["-t", "x"], sock: fake.path)
        check(r.status == 1 && r.stderr.contains("invalid url") && r.stdout.isEmpty, "server rejection: exit 1 and the reason on stderr")
        let rs = await run(["-t", "x", "--strict"], sock: fake.path)
        eq(rs.status, 1, "server rejection stays exit 1 with --strict")
        var evil = Data("{\"ok\":false,\"error\":\"bad".utf8)
        evil.append(contentsOf: [0x1B]); evil.append(contentsOf: Array("[31m red".utf8)); evil.append(contentsOf: [0x07, 0x08]); evil.append(contentsOf: Array("\"}\n".utf8))
        fake.reply = evil
        let re = await run(["-t", "x"], sock: fake.path)
        check(re.status == 1 && re.stderr.contains("bad") && !re.stderr.contains("\u{1B}") && !re.stderr.contains("\u{07}"), "terminal escapes from a hostile server are not echoed")
        fake.reply = Data("hello world\n".utf8)
        let rg = await run(["-t", "x"], sock: fake.path)
        check(rg.status == 1 && rg.stderr.contains("unexpected reply"), "an unrecognised reply: exit 1")
        fake.reply = Data()
        let rn = await run(["-t", "x"], sock: fake.path)
        check(rn.status == 0 && rn.stderr.contains("not running"), "a server that closes without replying: exit 0 with the hint")
        fake.reply = Data("{\"ok\":true,\"id\":\"x\"}\n".utf8)
        fake.replyDelay = 1.5
        let t = Date()
        let rd = await run(["-t", "slow"], sock: fake.path)
        check(rd.status == 0 && rd.stderr.isEmpty && Date().timeIntervalSince(t) >= 1.4, "a slow (1.5 s) server still gets its reply")
        fake.replyDelay = 0
    }

    section("atoll-notify: end to end against the real ingress server")
    do {
        let h = IngHarness(name: "e2e")
        try h.server.start()
        let t = Date()
        let r = await run(["-t", "Deploy \u{202E}done\nok", "-b", "Line1\nLine2 \u{00E9}\u{65E5}\u{1F600}", "-s", "sub", "-a", "My App", "-i", "com.apple.Terminal", "--symbol", "hammer.fill",
                           "-u", "https://example.com/build/42", "-p", "high", "--ttl", "9", "--dedupe", "build", "--thread", "ci", "--sensitive"], sock: h.path)
        check(r.status == 0 && r.stdout.isEmpty && r.stderr.isEmpty, "real server: exit 0, silent")
        check(Date().timeIntervalSince(t) < 1.5, "real server: the reply arrives at EOF (no deadline wait): \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
        let n = h.received.get().last
        eq(n?.title ?? "", "Deploy done ok", "bidi stripped and newline collapsed in the title")
        eq(n?.body ?? "", "Line1\nLine2 \u{00E9}\u{65E5}\u{1F600}", "multi-line unicode body survives")
        check(n?.subtitle == "sub" && n?.appName == "My App (via CLI)" && n?.bundleID == "com.apple.Terminal" && n?.iconSymbol == "hammer.fill", "subtitle, provenance app name, bundle id, symbol")
        check(n?.priority == .high && n?.ttl == 9 && n?.dedupeKey == "build" && n?.threadID == "ci" && n?.isSensitive == true && n?.source == .cli, "priority, ttl, dedupe, thread, sensitive, source")
        eq(n?.action ?? .none, .openURL(URL(string: "https://example.com/build/42")!), "url became an openURL action")
        let hostileTitle = "$(touch \(testRoot)/PWN9)"
        let r2 = await run(["-t", hostileTitle, "-b", "`touch \(testRoot)/PWN10`"], sock: h.path)
        check(r2.status == 0 && h.received.get().last?.title == hostileTitle, "a hostile title reaches the notification verbatim")
        check(!FileManager.default.fileExists(atPath: "\(testRoot)/PWN9") && !FileManager.default.fileExists(atPath: "\(testRoot)/PWN10"), "...and nothing was executed along the way")
        let n0 = h.received.get().count
        let bad = await run(["-t", "x", "-u", "javascript:alert(1)"], sock: h.path)
        check(bad.status == 1 && bad.stderr.contains("invalid url"), "javascript: url: rejected, exit 1, \"invalid url\"")
        let bad2 = await run(["-t", "x", "--symbol", "a b"], sock: h.path)
        check(bad2.status == 1 && bad2.stderr.contains("invalid symbol"), "invalid symbol: rejected")
        let bad3 = await run(["-t", "x", "-u", "https://a.b", "--tab", "agents"], sock: h.path)
        check(bad3.status == 1 && bad3.stderr.contains("only one of"), "two actions: rejected")
        let bad4 = await run(["-t", "x", "-i", "nodots"], sock: h.path)
        check(bad4.status == 1 && bad4.stderr.contains("invalid bundleID"), "invalid bundle id: rejected")
        let bad5 = await run(["-t", "x", "--ttl", "99999"], sock: h.path)
        check(bad5.status == 1 && bad5.stderr.contains("invalid ttl"), "ttl beyond the wire maximum: rejected")
        eq(h.received.get().count, n0, "no rejected request reached the handler")
        h.respond = { _ in .error("rate limited") }
        let rl = await run(["-t", "x"], sock: h.path)
        check(rl.status == 1 && rl.stderr.contains("rate limited"), "a queue-level rejection (rate limited) is exit 1 with the reason")
        h.respond = { .ok(id: $0.id) }
        let group = await withTaskGroup(of: Int32.self) { g -> [Int32] in
            for i in 0..<16 { g.addTask { await run(["-t", "burst\(i)"], sock: h.path).status } }
            var out: [Int32] = []
            for await s in g { out.append(s) }
            return out
        }
        check(group.allSatisfy { $0 == 0 }, "16 concurrent real scripts all succeed")
        check(await waitUntil { h.received.get().filter { $0.title.hasPrefix("burst") }.count == 16 }, "...and all 16 were delivered")
        check(Set(h.peers.get().map { $0.pid }).count > 5, "...from distinct peer pids (a per-pid limit alone cannot stop a shell loop)")
        h.server.stop()
        let gone = await run(["-t", "x"], sock: h.path)
        check(gone.status == 0 && gone.stderr.contains("not running"), "after the server stops the script reports not running and exits 0")
        let goneStrict = await run(["-t", "x", "--strict"], sock: h.path)
        eq(goneStrict.status, 3, "...and exits 3 with --strict")
    } catch { check(false, "e2e harness: \(error)") }
    check(FileManager.default.currentDirectoryPath == cwdBefore, "tests did not change the working directory")
}
