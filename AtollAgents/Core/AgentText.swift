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

/// Sanitiser for every string that originates from an agent (hook payloads, transcripts, registry files).
/// Everything is DISPLAY text from an untrusted local process: it is bounded, stripped of control, bidi and
/// invisible characters, and never interpreted (no markdown, no links, no paths opened).
enum AgentText {
    static let ellipsis = "\u{2026}"

    static func userFacingPrompt(_ input: String) -> String? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let internalPrefixes = ["<task-notification>", "<task_notification>", "<teammate-message", "<agent-notification>", "<local-command-stdout>", "<local-command-stderr>", "<command-stdout>", "<send_user_message_question_reply>", "<external_codex_apps_open_page>", "<environment_context>", "<permissions instructions>", "<turn_aborted>", "<system-reminder>", "<command-name>", "<command-message>", "<local-command", "<user-prompt-submit-hook>", "<bash-", "Caveat:", "[Request interrupted"]
        guard !internalPrefixes.contains(where: { t.hasPrefix($0) }) else { return nil }
        return cleanOptional(t, max: 200)
    }

    // MARK: Core sanitiser

    /// Cleans `input` for display. Output never contains control characters, bidi overrides, zero-width or other
    /// invisible format characters, and is at most `max` grapheme clusters long (including the ellipsis).
    /// - multiline: false collapses all whitespace (including newlines) to single spaces.
    ///   true keeps newlines (at most one blank line in a row) and collapses spaces/tabs.
    static func clean(_ input: String, max: Int = 200, multiline: Bool = false) -> String {
        guard max > 0 else { return "" }
        // Bound the work: a 100 MB string must cost the same as a 10 KB one.
        let scalarLimit = Swift.max(256, max * 12)
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(Swift.min(scalarLimit, 4096))
        var inputTruncated = false
        var count = 0
        for s in input.unicodeScalars {
            if count >= scalarLimit { inputTruncated = true; break }
            scalars.append(s)
            count += 1
        }

        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var newlineRun = 0
        var markRun = 0
        var atLineStart = true
        var i = 0
        let n = scalars.count

        func flushSpace() {
            if pendingSpace && !atLineStart { out.append(" ") }
            pendingSpace = false
        }

        while i < n {
            let s = scalars[i]
            let v = s.value

            // ANSI escape sequences: swallow the whole sequence, not just the ESC byte.
            if v == 0x1B {
                i += 1
                if i < n {
                    let c = scalars[i].value
                    if c == 0x5B { // CSI
                        i += 1
                        while i < n, !(0x40...0x7E).contains(scalars[i].value) { i += 1 }
                        i += 1
                    } else if c == 0x5D || c == 0x50 || c == 0x5F || c == 0x5E { // OSC / DCS / APC / PM
                        i += 1
                        while i < n {
                            if scalars[i].value == 0x07 { i += 1; break }
                            if scalars[i].value == 0x1B { i += 2; break }
                            i += 1
                        }
                    } else {
                        i += 1
                    }
                }
                continue
            }

            // Line breaks
            if v == 0x0A || v == 0x0D || v == 0x0B || v == 0x0C || v == 0x85 || v == 0x2028 || v == 0x2029 {
                if v == 0x0D, i + 1 < n, scalars[i + 1].value == 0x0A { i += 1 }
                i += 1
                if multiline {
                    pendingSpace = false
                    newlineRun += 1
                    if newlineRun <= 2 && !out.isEmpty { out.append("\n"); atLineStart = true }
                } else {
                    pendingSpace = true
                }
                markRun = 0
                continue
            }

            // Whitespace
            if v == 0x09 || s.properties.isWhitespace {
                pendingSpace = true
                markRun = 0
                i += 1
                continue
            }

            if shouldDrop(s) {
                // A zero-width joiner between two emoji is part of the glyph (family, flags of professions...). Keep it.
                if v == 0x200D, let prev = out.last, prev.value > 0xFF, prev.properties.isEmoji || prev.value == 0xFE0F,
                   i + 1 < n, scalars[i + 1].value > 0xFF, scalars[i + 1].properties.isEmoji {
                    out.append(s)
                }
                i += 1
                continue
            }

            // Zalgo: bound runs of combining marks.
            switch s.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                markRun += 1
                if markRun > 4 { i += 1; continue }
            default:
                markRun = 0
            }

            flushSpace()
            newlineRun = 0
            atLineStart = false
            out.append(s)
            i += 1
        }

        var result = String(out)
        // Trim trailing newlines/spaces.
        while let last = result.unicodeScalars.last, last == "\n" || last == " " { result.unicodeScalars.removeLast() }
        if result.isEmpty { return "" }
        return truncate(result, max: max, force: inputTruncated)
    }

    /// Cleaned value or nil when nothing printable is left.
    static func cleanOptional(_ s: String?, max: Int = 200, multiline: Bool = false) -> String? {
        guard let s = s else { return nil }
        let c = clean(s, max: max, multiline: multiline)
        return c.isEmpty ? nil : c
    }

    /// Truncates by grapheme count, appending an ellipsis, so the result is at most `max` graphemes.
    static func truncate(_ s: String, max: Int, force: Bool = false) -> String {
        guard max > 0 else { return "" }
        let total = s.count
        if total <= max && !force { return s }
        if total < max && force { return s + ellipsis }
        if max == 1 { return ellipsis }
        var head = String(s.prefix(max - 1))
        while let last = head.unicodeScalars.last, last == " " || last == "\n" { head.unicodeScalars.removeLast() }
        return head + ellipsis
    }

    /// True for scalars that must never reach the UI.
    static func shouldDrop(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 0x20 || (0x7F...0x9F).contains(v) { return true }
        switch v {
        case 0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFFA0, 0x034F, 0x180B...0x180F: return true  // invisible fillers / joiners
        case 0xE0000...0xE007F: return true                                                         // tag characters (hidden text)
        case 0xE0100...0xE01EF: return false                                                        // ideographic variation selectors are fine
        default: break
        }
        switch s.properties.generalCategory {
        case .control, .format, .privateUse, .surrogate: return true
        default: return false
        }
    }

    // MARK: Paths, hosts

    /// "/Users/me/very/long/path/to/file.swift" -> ".../to/file.swift" when longer than `max`.
    static func shortPath(_ path: String, max: Int = 80) -> String {
        let p = clean(path, max: 512)
        if p.count <= max { return p }
        let comps = p.split(separator: "/", omittingEmptySubsequences: true)
        if comps.count >= 2 {
            let tail = ellipsis + "/" + comps.suffix(2).joined(separator: "/")
            if tail.count <= max { return tail }
        }
        if let last = comps.last { return truncate(ellipsis + "/" + String(last), max: max) }
        return truncate(p, max: max)
    }

    /// Host of a URL string, lower-cased and sanitised. Nothing else (no path, query or credentials).
    static func host(of urlString: String) -> String? {
        let t = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 8192 else { return nil }
        var candidate = t
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let comps = URLComponents(string: candidate), let h = comps.host, !h.isEmpty else {
            return nil
        }
        let c = clean(h.lowercased(), max: 100)
        return c.isEmpty ? nil : c
    }

    /// `mcp__server__tool` -> ("server", "tool"). Tool names may themselves contain "__".
    static func mcpParts(_ toolName: String) -> (server: String, tool: String)? {
        guard toolName.hasPrefix("mcp__") else { return nil }
        let rest = toolName.dropFirst(5)
        guard let r = rest.range(of: "__") else { return nil }
        let server = String(rest[rest.startIndex..<r.lowerBound])
        let tool = String(rest[r.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    static func displayTool(_ name: String) -> String {
        let c = clean(name, max: 64)
        return c.isEmpty ? "tool" : c
    }

    // MARK: Tool summaries

    private static func string(_ input: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let s = input[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// Codex passes commands as ["bash","-lc","ls"]; Claude as a string.
    private static func commandText(_ input: [String: Any]) -> String? {
        for k in ["command", "cmd", "script"] {
            if let s = input[k] as? String, !s.isEmpty { return s }
            if let a = input[k] as? [Any] {
                let parts = a.compactMap { $0 as? String }
                if !parts.isEmpty {
                    // ["bash","-lc","real command"] -> real command
                    if parts.count >= 3, ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"].contains(parts[0]),
                       parts[1].hasPrefix("-"), parts[1].contains("c") {
                        return parts[2...].joined(separator: " ")
                    }
                    return parts.joined(separator: " ")
                }
            }
        }
        return nil
    }

    private static func firstLine(_ s: String) -> String {
        for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return ""
    }

    /// Extracts the first touched path from an apply_patch body.
    static func patchPath(_ text: String) -> String? {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).prefix(200) {
            for p in ["*** Update File:", "*** Add File:", "*** Delete File:", "*** Move to:"] where line.hasPrefix(p) {
                let path = line.dropFirst(p.count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { return path }
            }
        }
        return nil
    }

    /// Safe one-line summary of a tool call. Never longer than 160 graphemes.
    static func summary(tool: String, input: [String: Any]?) -> String {
        let inp = input ?? [:]
        var s = ""
        if let mcp = mcpParts(tool) {
            s = "\(mcp.server)/\(mcp.tool)"
            return clean(s, max: 160)
        }
        switch tool {
        case "Bash", "BashOutput", "exec_command", "shell", "local_shell", "container.exec", "KillShell":
            if let c = commandText(inp) { s = firstLine(c) }
            else if let id = string(inp, ["bash_id", "shell_id", "session_id"]) { s = id }
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            if let p = string(inp, ["file_path", "notebook_path", "path"]) { s = shortPath(p) }
        case "Read", "NotebookRead":
            if let p = string(inp, ["file_path", "notebook_path", "path"]) { s = shortPath(p) }
        case "LS":
            if let p = string(inp, ["path"]) { s = shortPath(p) }
        case "Glob":
            s = string(inp, ["pattern"]) ?? ""
            if let p = string(inp, ["path"]) { s += (s.isEmpty ? "" : " in ") + shortPath(p, max: 50) }
        case "Grep":
            s = string(inp, ["pattern"]) ?? ""
            if let p = string(inp, ["path"]) { s += (s.isEmpty ? "" : " in ") + shortPath(p, max: 50) }
        case "WebFetch":
            if let u = string(inp, ["url"]) { s = host(of: u) ?? "" }
        case "WebSearch", "web_search":
            s = string(inp, ["query"]) ?? ""
        case "Agent", "Task":
            s = string(inp, ["description"]) ?? string(inp, ["subagent_type"]) ?? firstLine(string(inp, ["prompt"]) ?? "")
        case "apply_patch":
            if let p = string(inp, ["input", "patch", "command"]), let path = patchPath(p) { s = shortPath(path) }
            else if let arr = inp["command"] as? [Any], let last = arr.last as? String, let path = patchPath(last) { s = shortPath(path) }
        case "TodoWrite":
            if let t = inp["todos"] as? [Any] { s = "\(t.count) todos" }
        case "update_plan":
            if let t = inp["plan"] as? [Any] { s = "\(t.count) steps" }
        case "TaskCreate":
            s = string(inp, ["subject", "title"]) ?? ""
        case "TaskUpdate":
            let id = string(inp, ["taskId", "task_id", "id"]) ?? (inp["taskId"] as? Int).map(String.init) ?? ""
            s = ["#" + id, string(inp, ["status"]) ?? ""].filter { $0 != "#" && !$0.isEmpty }.joined(separator: " ")
        default:
            break
        }
        if s.isEmpty { s = displayTool(tool) }
        return clean(s, max: 160)
    }

    /// Longer multi-line preview for the approval card. Never longer than `max` graphemes.
    static func detail(tool: String, input: [String: Any]?, max: Int = 1200) -> String? {
        guard let inp = input, !inp.isEmpty else { return nil }
        var out = ""
        switch tool {
        case "Bash", "exec_command", "shell", "local_shell":
            out = commandText(inp) ?? ""
            if let d = string(inp, ["description"]) { out = "# " + d + "\n" + out }
        case "Edit":
            if let p = string(inp, ["file_path", "path"]) { out = p }
            if let o = string(inp, ["old_string"]) { out += "\n- " + preview(o, 300) }
            if let n = string(inp, ["new_string"]) { out += "\n+ " + preview(n, 300) }
        case "Write":
            if let p = string(inp, ["file_path", "path"]) { out = p }
            if let c = string(inp, ["content"]) { out += "\n" + preview(c, 600) }
        case "MultiEdit":
            if let p = string(inp, ["file_path", "path"]) { out = p }
            if let e = inp["edits"] as? [Any] { out += "\n\(e.count) edits" }
        case "WebFetch":
            if let u = string(inp, ["url"]), let comps = URLComponents(string: u.contains("://") ? u : "https://" + u) {
                out = (comps.host ?? "") + comps.path   // no query, no fragment, no credentials
            }
            if let p = string(inp, ["prompt"]) { out += "\n" + preview(p, 300) }
        case "apply_patch":
            if let p = string(inp, ["input", "patch"]) { out = preview(p, 800) }
        default:
            if let mcp = mcpParts(tool) { out = "\(mcp.server)/\(mcp.tool)\n" }
            for k in inp.keys.sorted().prefix(6) {
                if let v = inp[k] as? String { out += "\(k): \(preview(v, 200))\n" }
                else if let v = inp[k] as? NSNumber { out += "\(k): \(v)\n" }
                else if inp[k] is [Any] || inp[k] is [String: Any] { out += "\(k): \(compactJSON(inp[k]!, maxChars: 200))\n" }
            }
        }
        let c = clean(out, max: max, multiline: true)
        return c.isEmpty ? nil : c
    }

    private static func preview(_ s: String, _ n: Int) -> String {
        clean(s, max: n, multiline: true).replacingOccurrences(of: "\n", with: "\n  ")
    }

    static func compactJSON(_ v: Any, maxChars: Int) -> String {
        guard JSONSerialization.isValidJSONObject(v) || v is [Any] || v is [String: Any],
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
              let s = String(data: d.prefix(maxChars * 4), encoding: .utf8) else { return "" }
        return clean(s, max: maxChars)
    }
}
