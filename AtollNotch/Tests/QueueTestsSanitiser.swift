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

// T3 (continued): sanitiser edge cases, identifier and URL validation, and the pure wire decoder of the ingress.

private let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"

private func decode(_ json: String, fileExists: @escaping (String) -> Bool = { _ in true }) -> Result<NotchNotification, NotificationIngressDecoder.Failure> {
    NotificationIngressDecoder.decode(Data(json.utf8), now: t0, fileExists: fileExists)
}

private func failure(_ json: String) -> NotificationIngressDecoder.Failure? {
    if case .failure(let f) = decode(json) { return f }
    return nil
}

func runSanitiserTests() {
    func clean(_ s: String, max: Int, multiline: Bool = false) -> String { NotificationText.clean(s, max: max, multiline: multiline) }
    section("Sanitiser: invisible and dangerous characters")
    for (name, v) in [("RLO", 0x202E), ("LRE", 0x202A), ("RLE", 0x202B), ("PDF", 0x202C), ("LRO", 0x202D), ("LRI", 0x2066), ("RLI", 0x2067),
                      ("FSI", 0x2068), ("PDI", 0x2069), ("LRM", 0x200E), ("RLM", 0x200F), ("ALM", 0x061C)] {
        eq(clean("abc\(String(UnicodeScalar(v)!))def", max: 50), "abcdef", "bidi control \(name) is stripped")
    }
    for (name, v) in [("ZWSP", 0x200B), ("ZWNJ", 0x200C), ("ZWJ alone", 0x200D), ("BOM", 0xFEFF), ("word joiner", 0x2060), ("soft hyphen", 0x00AD),
                      ("tag char", 0xE0041), ("hangul filler", 0x3164), ("mongolian vs", 0x180E)] {
        eq(clean("a\(String(UnicodeScalar(v)!))b", max: 50), "ab", "invisible \(name) is stripped")
    }
    eq(clean("a\0b", max: 50), "ab", "NUL is stripped")
    var ctrl = ""
    for v in 1...31 where ![9, 10, 11, 12, 13].contains(v) { ctrl += String(UnicodeScalar(UInt8(v))) }
    eq(clean("x" + ctrl + "y", max: 50), "xy", "every other C0 control character is stripped")
    eq(clean("x\u{7F}y", max: 50), "xy", "DEL is stripped")
    var c1 = ""
    for v in 0x80...0x9F where v != 0x85 { c1 += String(UnicodeScalar(UInt8(v))) }
    eq(clean("x" + c1 + "y", max: 50), "xy", "C1 controls are stripped")
    eq(clean("\u{1B}[31mred\u{1B}[0m", max: 50), "red", "ANSI CSI sequences are removed whole")
    eq(clean("a\u{1B}]0;evil title\u{7}b", max: 50), "ab", "ANSI OSC sequences are removed whole")
    eq(clean("a\u{1B}", max: 50), "a", "a dangling ESC is harmless")
    eq(clean("a\n\rb\r\nc\u{2028}d\u{2029}e\u{85}f", max: 50), "a b c d e f", "all line breaks collapse to a space in single-line mode")
    eq(clean("a\t\t b   c", max: 50), "a b c", "tabs and runs of spaces collapse")
    eq(clean("a\u{00A0}\u{00A0}b", max: 50), "a b", "no-break spaces collapse")
    eq(clean("   padded   ", max: 50), "padded", "outer whitespace is trimmed")
    eq(clean("", max: 50), "", "empty stays empty")
    eq(clean("\u{202E}\u{200B}  \n", max: 50), "", "only invisible characters becomes empty")
    check(NotificationText.cleanOptional("  \u{200B} ", max: 10) == nil, "cleanOptional returns nil for nothing printable")
    eq(NotificationText.cleanOptional("x", max: 10) ?? "", "x", "cleanOptional keeps real text")
    eq(clean("a\n\n\n\nb", max: 50, multiline: true), "a\n\nb", "multiline: at most one blank line")
    eq(clean("line1\nline2", max: 50, multiline: true), "line1\nline2", "multiline keeps single newlines")
    eq(clean("\n\nlead", max: 50, multiline: true), "lead", "multiline: leading newlines dropped")
    eq(clean("a   b\t c", max: 50, multiline: true), "a b c", "multiline still collapses spaces")
    eq(clean("café 日本語 \u{0645}\u{0631}\u{062D}\u{0628}\u{0627}", max: 50), "café 日本語 \u{0645}\u{0631}\u{062D}\u{0628}\u{0627}", "real text in other scripts is untouched")
    section("Sanitiser: lengths, graphemes, emoji, huge input")
    eq(clean(String(repeating: "a", count: 120), max: 120).count, 120, "exactly 120 graphemes is untouched")
    let t121 = clean(String(repeating: "a", count: 121), max: 120)
    check(t121.count == 120 && t121.hasSuffix("\u{2026}"), "121 graphemes is cut to 120 with an ellipsis")
    let t500 = clean(String(repeating: "b", count: 500), max: NotificationText.maxBody)
    check(t500.count == 400 && t500.hasSuffix("\u{2026}"), "body is cut to 400 graphemes")
    eq(clean(family, max: 5).count, 1, "a ZWJ family emoji is one grapheme and survives intact")
    eq(clean(family, max: 5), family, "...unchanged byte for byte")
    let fams = clean(String(repeating: family, count: 300), max: 120)
    check(fams.count == 120 && fams.dropLast().allSatisfy { String($0) == family }, "truncating emoji never splits a grapheme")
    eq(clean("\u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8}", max: 10).count, 2, "two flags stay two graphemes")
    eq(clean("\u{1F44D}\u{1F3FD}", max: 10).count, 1, "emoji with skin tone is one grapheme")
    eq(clean("a\u{200D}b", max: 10), "ab", "a stray ZWJ between letters is stripped")
    let zalgo = clean("a" + String(repeating: "\u{0301}", count: 60), max: 50)
    check(zalgo.unicodeScalars.count <= 5, "combining-mark floods are bounded")
    let t0clock = Date()
    let huge = clean(String(repeating: "x", count: 10_000_000), max: 120)
    check(Date().timeIntervalSince(t0clock) < 1.5, "a 10 MB input is processed in bounded time")
    check(huge.count <= 120 && huge.hasSuffix("\u{2026}"), "...and is truncated with an ellipsis")
    let hugeBody = clean(String(repeating: "line\n", count: 2_000_000), max: 400, multiline: true)
    check(hugeBody.count <= 400, "a huge multiline body is bounded")
    eq(NotificationText.truncate("abc", max: 1), "\u{2026}", "truncate to 1 is the ellipsis")
    eq(NotificationText.truncate("abc", max: 0), "", "truncate to 0 is empty")
    eq(NotificationText.truncate("abcdef", max: 4), "abc\u{2026}", "truncate keeps max-1 graphemes and the ellipsis")

    section("Validators: SF Symbol, bundle id, tab")
    for s in ["bell", "square.and.arrow.up", "1.circle", "hammer.fill", "a.b.c.d", "Foo9"] { check(NotificationText.symbol(s) == s, "symbol '\(s)' is valid") }
    for s in ["", "../x", "a b", "a;b", ".x", "x.", "a..b", String(repeating: "a", count: 65), "bell\u{202E}", "é", "bell/fill", "a\nb", "a-b", "a_b", "$(x)"] {
        check(NotificationText.symbol(s) == nil, "symbol \(s.debugDescription) is rejected")
    }
    check(NotificationText.symbol(String(repeating: "a", count: 64)) != nil, "64-character symbol is the maximum")
    check(NotificationText.symbol(nil) == nil, "nil symbol")
    for s in ["com.apple.Terminal", "org.mozilla.firefox", "com.foo-bar.App_1", "a.b"] { check(NotificationText.bundleID(s) == s, "bundle id '\(s)' is valid") }
    for s in ["", "x", "nodots", "com..apple", ".com.apple", "com.apple.", "com apple.x", "com.apple.\u{200B}x", "a.b/c", String(repeating: "a.", count: 90), "com.apple;ls"] {
        check(NotificationText.bundleID(s) == nil, "bundle id \(s.debugDescription.prefix(40)) is rejected")
    }
    check(NotificationText.tab("agents") == "agents" && NotificationText.tab("a-b_9") == "a-b_9", "valid tabs")
    for s in ["", "a b", "a/b", "a.b", String(repeating: "t", count: 33), "tab\n"] { check(NotificationText.tab(s) == nil, "tab \(s.debugDescription.prefix(20)) is rejected") }

    section("Validators: URLs (syntax only; custom schemes are not checked against installed apps)")
    func url(_ s: String, exists: Bool = true) -> URL? { NotificationURLPolicy.validate(s, fileExists: { _ in exists }) }
    for s in ["https://example.com", "http://example.com/a?b=1#c", "HTTPS://Example.COM/x", "https://localhost:8080/x", "mailto:a@b.co", "mailto:a@b.co?subject=Hi",
              "slack://channel?team=T1", "vscode://file/Users/x/a.swift:10", "x-callback-url://run", "obsidian://open?vault=v", "things:///show?id=today"] {
        check(url(s) != nil, "allowed: \(s)")
    }
    for s in ["javascript:alert(1)", "JavaScript:alert(1)", "  javascript:alert(1)", "java\nscript:alert(1)", "java\tscript:alert(1)", "data:text/html,<b>x</b>",
              "vbscript:x", "about:blank", "blob:https://x/y", "applescript://x", "ftp://example.com/x", "ws://example.com", "view-source:https://x",
              "", "   ", "not a url", "example.com", "//example.com/x", "1http://x", "ht tp://x", "https://", "http://:80", "mailto:", "slack:",
              "https://user:pw@example.com/x", "https://exa\u{202E}mple.com", "https://example.com/\u{200B}", "https://a.com/ b",
              String(repeating: "a", count: 3000)] {
        check(url(s) == nil, "rejected: \(s.debugDescription.prefix(48))")
    }
    check(url("file:///etc/hosts") != nil, "file: URL to an existing path is allowed")
    check(url("file:///nonexistent/path", exists: false) == nil, "file: URL to a missing path is rejected")
    check(url("file://localhost/etc/hosts") != nil, "file://localhost is allowed")
    check(url("file://evil.example/etc/hosts") == nil, "file: with a remote host is rejected")
    check(url("file:///Applications/Foo.app") == nil, "file: pointing at an app bundle is rejected (it would launch)")
    check(url("file:///tmp/x.command") == nil, "file: pointing at a .command script is rejected")
    check(url("file:///tmp/x.WORKFLOW") == nil, "extension check is case-insensitive")
    check(url("file:///tmp/a/../b/x.terminal") == nil, "path tricks do not hide a launchable extension")
    check(url("file:///tmp/notes.txt") != nil, "a plain text file is fine")
    do {  // a symlink must not smuggle a launchable target
        let dir = makeTmp("lnk")
        write(dir + "/real.command", "#!/bin/sh\n")
        symlink(dir + "/real.command", dir + "/innocent.txt")
        check(NotificationURLPolicy.validate("file://" + dir + "/innocent.txt") == nil, "a symlink to a .command file is rejected (real filesystem)")
        write(dir + "/ok.txt", "x")
        check(NotificationURLPolicy.validate("file://" + dir + "/ok.txt") != nil, "an existing plain file passes the real filesystem check")
        check(NotificationURLPolicy.validate("file://" + dir + "/missing.txt") == nil, "a missing file fails the real filesystem check")
    }
    eq(url("HTTPS://Example.COM/x")?.scheme ?? "", "https", "scheme is normalised to lower case")
    check(NotificationURLPolicy.isValidScheme("x-cb.url+1") && !NotificationURLPolicy.isValidScheme("1x") && !NotificationURLPolicy.isValidScheme("X"), "scheme syntax")

    section("Ingress decoder: valid requests")
    if case .success(let n) = decode("{\"v\":1,\"title\":\"Hi\"}") {
        check(n.source == .cli && n.title == "Hi" && n.priority == .normal && n.action == .none && !n.isSensitive, "minimal request")
        eq(n.appName, "atoll-notify", "default app name")
        eq(n.receivedAt, t0, "receivedAt comes from the server clock")
        check(n.ttl == nil && n.body == nil && n.subtitle == nil && n.dedupeKey == nil && n.threadID == nil, "optional fields are nil")
    } else { check(false, "minimal request must decode") }
    if case .success(let n) = decode("{\"v\":1,\"title\":\"T\",\"body\":\"B\",\"subtitle\":\"S\",\"app\":\"make\",\"bundleID\":\"com.apple.Terminal\",\"symbol\":\"hammer.fill\",\"url\":\"https://example.com\",\"priority\":\"high\",\"ttl\":6.5,\"dedupe\":\"d\",\"thread\":\"th\",\"sensitive\":true}") {
        check(n.title == "T" && n.body == "B" && n.subtitle == "S" && n.bundleID == "com.apple.Terminal" && n.iconSymbol == "hammer.fill", "all text fields")
        eq(n.appName, "make (via CLI)", "app name always carries provenance")
        check(n.priority == .high && n.ttl == 6.5 && n.dedupeKey == "d" && n.threadID == "th" && n.isSensitive, "priority, ttl, dedupe, thread, sensitive")
        eq(n.action, .openURL(URL(string: "https://example.com")!), "url becomes an openURL action")
    } else { check(false, "full request must decode") }
    if case .success(let n) = decode("{\"v\":1,\"title\":\"T\",\"openApp\":\"com.apple.Terminal\"}") { eq(n.action, .activateApp(bundleID: "com.apple.Terminal"), "openApp action") } else { check(false, "openApp") }
    if case .success(let n) = decode("{\"v\":1,\"title\":\"T\",\"tab\":\"agents\"}") { eq(n.action, .openNotchTab("agents"), "tab action") } else { check(false, "tab") }
    if case .success(let n) = decode("{\"v\":1,\"title\":\"T\",\"priority\":\"CRITICAL\"}") { eq(n.priority, .critical, "priority is case-insensitive") } else { check(false, "priority case") }
    if case .success(let n) = decode("{\"v\":1,\"title\":\"T\",\"ttl\":3600}") { eq(n.ttl ?? 0, 3600, "ttl 3600 is the maximum accepted by the wire decoder") } else { check(false, "ttl max") }
    if case .success = decode("{\"v\":1,\"title\":\"T\",\"future\":{\"a\":1},\"body\":null,\"url\":\"\",\"tab\":\"\"}") { check(true, "unknown keys, nulls and empty strings are ignored") } else { check(false, "unknown keys") }
    if case .success(let n) = decode("{\"v\":1,\"title\":\"a\\u202Eb\\u0000c\\n\\u001b[31md\"}") { eq(n.title, "abc d", "control and bidi characters in the title are cleaned") } else { check(false, "title cleaning") }
    if case .success(let n) = decode("{\"v\":1,\"title\":\"x\",\"app\":\"\(String(repeating: "A", count: 100))\"}") { check(n.appName.hasSuffix(" (via CLI)") && n.appName.count <= 40 + 10, "long app names are bounded before the suffix") } else { check(false, "app") }
    if case .success(let n) = decode("{\"v\":1,\"title\":\"x\",\"app\":\"Mail\\u202E\"}") { eq(n.appName, "Mail (via CLI)", "bidi in the app name is stripped") } else { check(false, "app bidi") }
    do {
        var bytes = Array("{\"v\":1,\"title\":\"bad".utf8); bytes += [0xFF, 0xFE]; bytes += Array("bytes\"}".utf8)
        if case .success(let n) = NotificationIngressDecoder.decode(Data(bytes), now: t0) { check(n.title.contains("bad") && n.title.contains("bytes"), "invalid UTF-8 is repaired, not rejected") } else { check(false, "invalid utf-8") }
    }
    section("Ingress decoder: rejections (fixed messages, nothing echoed)")
    eq(NotificationIngressDecoder.decode(Data(), now: t0).failureValue, .malformed, "empty payload")
    for (name, j) in [("not json", "garbage"), ("array", "[1,2]"), ("null", "null"), ("string", "\"x\""), ("truncated", "{\"v\":1,\"title\":\"x"), ("missing comma", "{\"v\":1 \"title\":\"x\"}")] {
        eq(failure(j) ?? .multipleActions, .malformed, "malformed: \(name)")
    }
    for (name, j) in [("missing v", "{\"title\":\"x\"}"), ("v=2", "{\"v\":2,\"title\":\"x\"}"), ("v string", "{\"v\":\"1\",\"title\":\"x\"}"),
                      ("v=1.5", "{\"v\":1.5,\"title\":\"x\"}"), ("v bool", "{\"v\":true,\"title\":\"x\"}"), ("v=0", "{\"v\":0,\"title\":\"x\"}")] {
        eq(failure(j) ?? .malformed, .unsupportedVersion, "version: \(name)")
    }
    for (name, j) in [("absent", "{\"v\":1}"), ("empty", "{\"v\":1,\"title\":\"\"}"), ("blank", "{\"v\":1,\"title\":\"  \"}"), ("null", "{\"v\":1,\"title\":null}"),
                      ("invisible only", "{\"v\":1,\"title\":\"\\u200b\\u202e\"}")] {
        eq(failure(j) ?? .malformed, .missingTitle, "title \(name)")
    }
    eq(failure("{\"v\":1,\"title\":5}") ?? .malformed, .wrongType("title"), "title of the wrong type")
    eq(failure("{\"v\":1,\"title\":\"x\",\"body\":5}") ?? .malformed, .wrongType("body"), "body of the wrong type")
    eq(failure("{\"v\":1,\"title\":\"x\",\"tab\":[]}") ?? .malformed, .wrongType("tab"), "tab of the wrong type")
    eq(failure("{\"v\":1,\"title\":\"x\",\"priority\":3}") ?? .malformed, .wrongType("priority"), "numeric priority")
    eq(failure("{\"v\":1,\"title\":\"x\",\"priority\":\"urgent\"}") ?? .malformed, .invalid("priority"), "unknown priority")
    for (name, v) in [("string", "\"5\""), ("bool", "true"), ("object", "{}")] { eq(failure("{\"v\":1,\"title\":\"x\",\"ttl\":\(v)}") ?? .malformed, .wrongType("ttl"), "ttl \(name)") }
    for (name, v) in [("zero", "0"), ("negative", "-1"), ("too large", "3601"), ("huge", "1e308")] { eq(failure("{\"v\":1,\"title\":\"x\",\"ttl\":\(v)}") ?? .malformed, .invalid("ttl"), "ttl \(name)") }
    for (name, v) in [("string", "\"yes\""), ("number", "1")] { eq(failure("{\"v\":1,\"title\":\"x\",\"sensitive\":\(v)}") ?? .malformed, .wrongType("sensitive"), "sensitive \(name)") }
    eq(failure("{\"v\":1,\"title\":\"x\",\"symbol\":\"bad name\"}") ?? .malformed, .invalid("symbol"), "invalid symbol")
    eq(failure("{\"v\":1,\"title\":\"x\",\"bundleID\":\"nodots\"}") ?? .malformed, .invalid("bundleID"), "invalid bundleID")
    eq(failure("{\"v\":1,\"title\":\"x\",\"url\":\"javascript:alert(1)\"}") ?? .malformed, .invalid("url"), "javascript: url")
    eq(failure("{\"v\":1,\"title\":\"x\",\"url\":\"data:text/html,x\"}") ?? .malformed, .invalid("url"), "data: url")
    eq(failure("{\"v\":1,\"title\":\"x\",\"openApp\":\"nodots\"}") ?? .malformed, .invalid("openApp"), "invalid openApp")
    eq(failure("{\"v\":1,\"title\":\"x\",\"tab\":\"a b\"}") ?? .malformed, .invalid("tab"), "invalid tab")
    eq(failure("{\"v\":1,\"title\":\"x\",\"url\":\"https://a.b\",\"tab\":\"agents\"}") ?? .malformed, .multipleActions, "two actions are refused")
    eq(failure("{\"v\":1,\"title\":\"x\",\"url\":\"https://a.b\",\"openApp\":\"com.a.b\",\"tab\":\"t\"}") ?? .malformed, .multipleActions, "three actions are refused")
    if case .failure(let f) = decode("{\"v\":1,\"title\":\"x\",\"priority\":\"<script>alert(1)</script>\"}") { check(!f.message.contains("script"), "error messages never echo what the client sent") }
    let tDeep = Date()
    eq(failure(String(repeating: "[", count: 900_000)) ?? .multipleActions, .malformed, "a 900,000-deep nested array is malformed, not a crash")
    eq(failure("{\"v\":1,\"title\":\"x\",\"a\":" + String(repeating: "{\"a\":", count: 100_000)) ?? .multipleActions, .malformed, "a 100,000-deep nested object is malformed, not a crash")
    check(Date().timeIntervalSince(tDeep) < 3, "...both in bounded time")
    check(NotificationIngressDecoder.Failure.malformed.message == "malformed JSON" && NotificationIngressDecoder.Failure.missingTitle.message == "title is required", "fixed message texts")
    check(decode("{\"v\":1,\"title\":\"x\",\"url\":\"file:///nonexistent\"}", fileExists: { _ in false }).failureValue == .invalid("url"), "file: url honours the injected existence check")
    section("Ingress reply lines")
    let id = UUID()
    let okLine = String(decoding: IngressReply.ok(id: id).line, as: UTF8.self)
    check(okLine.hasSuffix("\n") && okLine.filter { $0 == "\n" }.count == 1, "ok reply is exactly one line")
    eq(jsonObject(okLine)?["id"] as? String ?? "", id.uuidString, "ok reply carries the id")
    eq(jsonObject(okLine)?["ok"] as? Bool ?? false, true, "ok reply has ok:true")
    let errLine = String(decoding: IngressReply.error("rate limited").line, as: UTF8.self)
    check(jsonObject(errLine)?["ok"] as? Bool == false && jsonObject(errLine)?["error"] as? String == "rate limited" && errLine.filter { $0 == "\n" }.count == 1, "error reply is one line with ok:false")
    let weird = String(decoding: IngressReply.error("quote \" and \n newline").line, as: UTF8.self)
    check(weird.filter { $0 == "\n" }.count == 1 && jsonObject(weird) != nil, "error replies stay single-line valid JSON even for odd text")
}

extension Result {
    var failureValue: Failure? { if case .failure(let f) = self { return f }; return nil }
}
