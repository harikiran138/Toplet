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

func runTextTests() {
    section("AgentText.clean")
    eq(AgentText.clean("  hello   world \n"), "hello world", "collapses whitespace and trims")
    eq(AgentText.clean("a\u{0}b"), "ab", "NUL is stripped")
    eq(AgentText.clean("abc\u{202E}def"), "abcdef", "bidi RLO stripped")
    eq(AgentText.clean("a\u{2066}b\u{2069}c\u{200E}d\u{200F}e\u{061C}f"), "abcdef", "bidi isolates and marks stripped")
    eq(AgentText.clean("a\u{200B}b\u{FEFF}c\u{2060}d\u{200C}e"), "abcde", "zero-width characters stripped")
    eq(AgentText.clean("a\u{200D}b"), "ab", "ZWJ between letters is stripped")
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    eq(AgentText.clean(family), family, "ZWJ emoji sequence is kept intact")
    eq(AgentText.clean(family).count, 1, "ZWJ emoji family is one grapheme")
    let emojis = String(repeating: "\u{1F600}", count: 10)
    let t = AgentText.clean(emojis, max: 5)
    eq(t.count, 5, "truncation counts graphemes, ellipsis included")
    check(t.hasSuffix("\u{2026}"), "truncated text ends with an ellipsis")
    eq(AgentText.clean("abcdef", max: 6), "abcdef", "exact fit is not truncated")
    eq(AgentText.clean("abcdefg", max: 6), "abcde\u{2026}", "one over is truncated")
    eq(AgentText.clean("abc", max: 1), "abc".count <= 1 ? "abc" : "\u{2026}", "max 1 gives only an ellipsis")
    eq(AgentText.clean("abc", max: 0), "", "max 0 gives an empty string")
    eq(AgentText.clean("\u{1B}[31mred\u{1B}[0m"), "red", "ANSI CSI sequences are removed whole")
    eq(AgentText.clean("a\u{1B}]0;evil title\u{07}b"), "ab", "OSC sequences are removed whole")
    eq(AgentText.clean("x\r\ny\tz\u{0B}w"), "x y z w", "CR LF TAB VT become spaces in single-line mode")
    eq(AgentText.clean("a\u{2028}b\u{2029}c\u{85}d"), "a b c d", "unicode line separators become spaces")
    eq(AgentText.clean("a\u{E0041}\u{E0042}b"), "ab", "tag characters (hidden text) are stripped")
    eq(AgentText.clean("a\u{3164}b\u{115F}c"), "abc", "invisible filler characters are stripped")
    eq(AgentText.clean("a\u{00A0}\u{2003}b"), "a b", "NBSP and em-space collapse to a space")
    let zalgo = "a" + String(repeating: "\u{0301}", count: 200)
    eq(zalgo.count, 1, "zalgo fixture is one grapheme")
    check(AgentText.clean(zalgo).unicodeScalars.count <= 6, "runs of combining marks are bounded")
    eq(AgentText.clean("l1\nl2\n\n\n\nl3", multiline: true), "l1\nl2\n\nl3", "multiline keeps newlines, at most one blank line")
    eq(AgentText.clean("  a   b  ", multiline: true), "a b", "multiline collapses spaces")
    eq(AgentText.clean("e\u{0301}"), "e\u{0301}", "legitimate combining accent is kept")
    eq(AgentText.clean("\u{202E}"), "", "only invisible characters gives an empty string")
    check(AgentText.cleanOptional("   \u{200B} ") == nil, "cleanOptional returns nil for blank input")
    check(AgentText.cleanOptional(nil) == nil, "cleanOptional(nil) is nil")

    let t0 = Date()
    let huge = String(repeating: "x", count: 5_000_000)
    let h = AgentText.clean(huge, max: 100)
    check(h.count <= 100, "5 MB string is truncated to the limit")
    check(Date().timeIntervalSince(t0) < 1.0, "5 MB string is cleaned in bounded time")
    let hugeSpaces = String(repeating: " ", count: 3_000_000) + "tail"
    check(AgentText.clean(hugeSpaces, max: 50).count <= 50, "3 MB of spaces does not blow up")
    let nulBomb = String(repeating: "\u{0}", count: 1_000_000)
    eq(AgentText.clean(nulBomb), "", "1 MB of NULs gives an empty string")

    section("AgentText.summary")
    eq(AgentText.summary(tool: "Bash", input: ["command": "npm test\nrm -rf /"]), "npm test", "Bash: first line of the command")
    eq(AgentText.summary(tool: "Bash", input: ["command": "\n\n  ls -la  \nmore"]), "ls -la", "Bash: skips leading blank lines")
    eq(AgentText.summary(tool: "Edit", input: ["file_path": "/a/b/Package.swift"]), "/a/b/Package.swift", "Edit: path")
    eq(AgentText.summary(tool: "Write", input: ["file_path": "/tmp/x.txt", "content": "secret"]), "/tmp/x.txt", "Write: path only, never content")
    eq(AgentText.summary(tool: "MultiEdit", input: ["file_path": "/tmp/m.swift", "edits": []]), "/tmp/m.swift", "MultiEdit: path")
    let long = "/Users/someone/very/long/path/that/goes/on/and/on/and/on/and/on/and/on/and/on/deep/inside/File.swift"
    let sp = AgentText.summary(tool: "Edit", input: ["file_path": long])
    check(sp.count <= 80 && sp.hasSuffix("inside/File.swift"), "Edit: long path is shortened to its tail")
    eq(AgentText.summary(tool: "Read", input: ["file_path": "/etc/hosts"]), "/etc/hosts", "Read: path")
    eq(AgentText.summary(tool: "Glob", input: ["pattern": "**/*.swift"]), "**/*.swift", "Glob: pattern")
    eq(AgentText.summary(tool: "Glob", input: ["pattern": "*.md", "path": "/docs"]), "*.md in /docs", "Glob: pattern and path")
    eq(AgentText.summary(tool: "Grep", input: ["pattern": "TODO", "path": "/src"]), "TODO in /src", "Grep: pattern and path")
    eq(AgentText.summary(tool: "WebFetch", input: ["url": "https://user:pw@Example.COM:8443/path?token=abc#frag"]), "example.com", "WebFetch: host only (no credentials, path, query)")
    eq(AgentText.summary(tool: "WebFetch", input: ["url": "not a url at all"]), "WebFetch", "WebFetch: unparsable url falls back to the tool name")
    eq(AgentText.summary(tool: "WebFetch", input: [:]), "WebFetch", "WebFetch: missing url falls back to the tool name")
    eq(AgentText.summary(tool: "Agent", input: ["description": "Explore the repo", "prompt": "long"]), "Explore the repo", "Agent: description")
    eq(AgentText.summary(tool: "Task", input: ["subagent_type": "Explore"]), "Explore", "Task: falls back to subagent_type")
    eq(AgentText.summary(tool: "mcp__github__create_issue", input: ["title": "x"]), "github/create_issue", "mcp: server/tool")
    eq(AgentText.summary(tool: "mcp__claude-vscode__getDiagnostics", input: nil), "claude-vscode/getDiagnostics", "mcp: hyphenated server")
    eq(AgentText.summary(tool: "mcp__srv__ns__tool", input: nil), "srv/ns__tool", "mcp: tool names may contain double underscores")
    eq(AgentText.summary(tool: "SomethingNew", input: ["x": 1]), "SomethingNew", "unknown tool: its name")
    eq(AgentText.summary(tool: "Bad\u{202E}Tool\u{0}", input: nil), "BadTool", "unknown tool name is sanitised")
    eq(AgentText.summary(tool: "Bash", input: ["command": 42]), "Bash", "wrong type for command falls back to the name")
    eq(AgentText.summary(tool: "Bash", input: nil), "Bash", "nil input falls back to the name")
    eq(AgentText.summary(tool: "exec_command", input: ["command": ["bash", "-lc", "make all"]]), "make all", "Codex: [bash,-lc,cmd] array is unwrapped")
    eq(AgentText.summary(tool: "exec_command", input: ["cmd": "git status"]), "git status", "Codex: cmd key")
    eq(AgentText.summary(tool: "apply_patch", input: ["input": "*** Begin Patch\n*** Update File: src/a.swift\n@@"]), "src/a.swift", "Codex apply_patch: first path")
    eq(AgentText.summary(tool: "TodoWrite", input: ["todos": [[String: Any](), [String: Any]()]]), "2 todos", "TodoWrite: count")
    eq(AgentText.summary(tool: "update_plan", input: ["plan": [1, 2, 3]]), "3 steps", "update_plan: step count")
    check(AgentText.summary(tool: "Bash", input: ["command": String(repeating: "a", count: 10_000)]).count <= 160, "summary is bounded to 160")
    check(!AgentText.summary(tool: "Bash", input: ["command": "echo \u{1B}[31mhi\u{202E}"]).contains("\u{1B}"), "summary has no escape characters")

    section("AgentText helpers")
    eq(AgentText.host(of: "example.com/path") ?? "nil", "example.com", "host: scheme-less url")
    eq(AgentText.host(of: "http://LOCALHOST:3000/x") ?? "nil", "localhost", "host: lower-cased, port dropped")
    check(AgentText.host(of: "") == nil, "host: empty is nil")
    check(AgentText.host(of: String(repeating: "a", count: 9000)) == nil, "host: absurdly long input is nil")
    check(AgentText.mcpParts("mcp__only") == nil, "mcpParts: missing tool is nil")
    check(AgentText.mcpParts("Bash") == nil, "mcpParts: non-mcp is nil")
    eq(AgentText.patchPath("*** Add File: new/file.txt\n+x") ?? "nil", "new/file.txt", "patchPath: Add File")
    check(AgentText.shortPath("/a/b").count <= 80, "shortPath: short input unchanged")
    let d = AgentText.detail(tool: "Bash", input: ["command": "make\nmake install", "description": "Build"]) ?? ""
    check(d.contains("# Build") && d.contains("make install"), "detail: Bash shows description and the whole command")
    let de = AgentText.detail(tool: "Edit", input: ["file_path": "/p.swift", "old_string": "a", "new_string": "b"]) ?? ""
    check(de.contains("- a") && de.contains("+ b"), "detail: Edit shows old and new")
    let dw = AgentText.detail(tool: "WebFetch", input: ["url": "https://x.example/a/b?secret=1"]) ?? ""
    check(dw.contains("x.example/a/b") && !dw.contains("secret"), "detail: WebFetch drops the query string")
    check(AgentText.detail(tool: "Bash", input: [:]) == nil, "detail: empty input is nil")
    check((AgentText.detail(tool: "Write", input: ["file_path": "/f", "content": String(repeating: "z", count: 100_000)]) ?? "").count <= 1200, "detail is bounded")
}
