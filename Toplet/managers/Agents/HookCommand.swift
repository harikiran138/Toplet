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

/// The exact, byte-stable hook command strings Atoll installs into Claude Code and Codex.
///
/// BYTE STABILITY IS A FEATURE. Codex trusts a hook by the hash of its definition; any byte change makes the
/// user re-review it with `/hooks`, and Codex skips changed hooks until then (docs/AI-AGENTS-HOOK-FORMATS.md).
/// Never edit the templates below casually: if they must change, bump `commandVersion`, update the pin test in
/// AtollAgents/Tests/HooksTests.swift, and expect users to re-trust. Old versions are recognised as "stale Atoll
/// entries" and replaced on the next install.
///
/// The hook is a pure POSIX shell one-liner (no python, no helper binary) that works in sh, bash and zsh:
///   S="<socket>"; [ -S "$S" ] || exit 0; { printf '<header>\n' "$PPID"; cat; } | /usr/bin/nc [-w 1] -U "$S" ...; exit 0
/// - socket missing -> exit 0 immediately, no process spawned, empty stdout (agent behaves as if Atoll did not exist)
/// - stale socket / refused -> nc fails quietly, `; exit 0` hides the status (any other exit code shows a "hook error" notice)
/// - non-blocking events: stdout and stderr go to /dev/null (UserPromptSubmit/SessionStart stdout would otherwise be
///   injected into the model context), `nc -w 1` gives up after 1 s of inactivity
/// - PermissionRequest: the ONLY blocking hook and the ONLY one whose stdout is passed through (the server's decision JSON)
enum HookCommand {
    /// Bump when ANY command byte changes.
    static let commandVersion = 1

    /// Literal text placed inside double quotes in the shell command; `$HOME` is expanded by the shell at run time.
    static let defaultSocketShellLiteral = "$HOME/.atoll/run/agent.sock"
    /// What the literal above means for the server (the server creates the directory, never the installer).
    static var defaultSocketRelativeToHome: String { ".atoll/run/agent.sock" }

    /// Hook `timeout` (seconds) for the blocking PermissionRequest hook.
    /// JUSTIFICATION: Atoll answers (or deliberately closes without answering so the agent falls back to its own
    /// prompt) after its own approval timeout, default ~120 s and clamped to `maxApprovalTimeoutSeconds`. The hook
    /// timeout is only the backstop for a WEDGED Atoll (alive but never closing the connection). It must therefore
    /// be larger than Atoll's longest approval timeout (so a slow human never races it) but small enough that a
    /// wedged Atoll cannot hold an agent for hours. Claude Island uses 86400 (24 h); we do not: whether the
    /// terminal dialog stays visible while a hook waits is UNKNOWN (research 0.4), so a wedge must be bounded.
    /// 900 s = 15 min = 1.5 x the 600 s ceiling, equal to the agents' own default-timeout order of magnitude (600 s).
    static let permissionRequestTimeout = 900
    /// The core's approval timeout MUST be clamped to this. (Stays below `permissionRequestTimeout`.)
    static let maxApprovalTimeoutSeconds = 600
    /// Non-blocking events: nc -w 1 plus process spawn fits comfortably in 3 s.
    static let nonBlockingTimeout = 3
    /// SessionEnd (Claude) / SessionEnd + Interrupt (Codex): Claude's default budget is 1.5 s, Codex's is 1 s (max 3 s).
    /// 2 s is enough for nc -w 1 and stays tiny so quitting an agent is never delayed.
    static let shortEventTimeout = 2

    /// macOS sockaddr_un.sun_path is 104 bytes including the NUL.
    static let maxSocketPathBytes = 103

    /// Events Atoll needs from Claude Code. Verified against the published settings JSON schema on 2026-10-21.
    static let claudeEventNames = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure", "SubagentStart",
        "SubagentStop", "TeammateIdle", "TaskCreated", "TaskCompleted", "PreCompact", "PostCompact",
    ]

    /// The 12 Codex hook events (https://learn.chatgpt.com/docs/hooks.md).
    static let codexEventNames = [
        "SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "PreToolUse", "PermissionRequest",
        "PostToolUse", "PreCompact", "PostCompact", "UserPromptSubmit", "Stop", "Interrupt",
    ]

    struct Entry: Equatable {
        let event: String
        let command: String
        let timeout: Int
        let blocking: Bool
    }

    static func eventNames(for agent: AgentKind) -> [String] { agent == .claudeCode ? claudeEventNames : codexEventNames }

    static func timeout(for agent: AgentKind, event: String) -> Int {
        if event == "PermissionRequest" { return permissionRequestTimeout }
        if event == "SessionEnd" || event == "Interrupt" { return shortEventTimeout }
        return nonBlockingTimeout
    }

    /// One entry per event, in the order Atoll wants them written. `socketPath == nil` = the default path.
    static func entries(for agent: AgentKind, socketPath: String? = nil, home: String = NSHomeDirectory()) throws -> [Entry] {
        let lit = try socketShellLiteral(socketPath, home: home)
        return eventNames(for: agent).map { ev in
            let blocking = ev == "PermissionRequest"
            return Entry(event: ev, command: command(agent: agent, blocking: blocking, socketLiteral: lit),
                         timeout: timeout(for: agent, event: ev), blocking: blocking)
        }
    }

    /// THE template. Do not reformat.
    static func command(agent: AgentKind, blocking: Bool, socketLiteral: String) -> String {
        let header = "{\"v\":1,\"agent\":\"\(agent.rawValue)\",\"ppid\":%s}"
        let nc = blocking
            ? "/usr/bin/nc -U \"$S\" 2>/dev/null"
            : "/usr/bin/nc -w 1 -U \"$S\" >/dev/null 2>&1"
        return "S=\"\(socketLiteral)\"; [ -S \"$S\" ] || exit 0; { printf '\(header)\\n' \"$PPID\"; cat; } | \(nc); exit 0"
    }

    /// Validates a custom socket path and converts it into the text that goes between the double quotes.
    /// Accepts an absolute path, `~/...` or `$HOME/...`. Everything else is escaped so it can never become
    /// shell syntax (`"`, `\`, `$`, backtick). Rejects control characters and paths that cannot fit in sun_path.
    static func socketShellLiteral(_ path: String?, home: String = NSHomeDirectory()) throws -> String {
        guard let path = path else { return defaultSocketShellLiteral }
        if path.isEmpty { throw HookInstallError.invalidSocketPath("empty path") }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw HookInstallError.invalidSocketPath("path contains a control character")
        }
        var prefixLiteral = ""
        var rest = path
        var resolvedForLength = path
        if path.hasPrefix("~/") {
            prefixLiteral = "$HOME/"; rest = String(path.dropFirst(2)); resolvedForLength = home + "/" + rest
        } else if path.hasPrefix("$HOME/") {
            prefixLiteral = "$HOME/"; rest = String(path.dropFirst(6)); resolvedForLength = home + "/" + rest
        } else if !path.hasPrefix("/") {
            throw HookInstallError.invalidSocketPath("path must be absolute, ~/..., or $HOME/...")
        }
        if resolvedForLength.utf8.count > maxSocketPathBytes {
            throw HookInstallError.invalidSocketPath("path is longer than \(maxSocketPathBytes) bytes (macOS sun_path limit)")
        }
        var escaped = ""
        for ch in rest {
            if ch == "\\" || ch == "\"" || ch == "$" || ch == "`" { escaped.append("\\") }
            escaped.append(ch)
        }
        return prefixLiteral + escaped
    }

    /// True for any command that carries Atoll's wire header for this agent and goes through /usr/bin/nc.
    /// Used ONLY to recognise Atoll's own older/other-socket entries ("stale"); the exact string decides "installed".
    static func looksLikeAtoll(_ command: String, agent: AgentKind) -> Bool {
        command.contains("{\"v\":1,\"agent\":\"\(agent.rawValue)\",\"ppid\":%s}")
            && command.contains("/usr/bin/nc")
            && command.contains("[ -S \"$S\" ] || exit 0")
    }
}
