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

/// What AgentCenter needs from the hook installer (owned by the hooks module). `HookInstaller` conforms to this.
/// All calls are synchronous file operations; AgentCenter calls them from the main actor on explicit user actions.
public protocol HookInstalling {
    /// Human-readable diff of what `install` would change (empty string = nothing to do).
    func preview() -> String
    /// Installs Atoll's marked hook entries for the selected agents (backup + atomic write; refuses on parse errors).
    func install(claude: Bool, codex: Bool) throws
    /// Removes only Atoll's marked entries.
    func uninstall() throws
    /// Current state, read-only.
    func state() -> HooksState
}

/// Default installer: installs nothing, but reports state by looking for Atoll's marker in the agents' hook files.
public struct NoopHookInstaller: HookInstalling {
    public var inspector: HookMarkerInspector
    public init(inspector: HookMarkerInspector = HookMarkerInspector()) { self.inspector = inspector }
    public func preview() -> String { "" }
    public func install(claude: Bool, codex: Bool) throws {}
    public func uninstall() throws {}
    public func state() -> HooksState { inspector.state() }
}

/// Read-only check: does `~/.claude/settings.json` / `~/.codex/hooks.json` (or config.toml) contain Atoll's hook marker?
/// Respects CLAUDE_CONFIG_DIR and CODEX_HOME. Never writes.
public struct HookMarkerInspector {
    public var claudeSettingsPaths: [String]
    public var codexHookPaths: [String]
    /// Substrings that identify an Atoll-managed hook command (socket path is stable by design, research 2.8).
    public var markers: [String]

    public init(claudeDir: String? = nil, codexDir: String? = nil, markers: [String] = [".atoll/run/agent.sock", "atoll-agent-hook"]) {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let cd = claudeDir ?? env["CLAUDE_CONFIG_DIR"] ?? (home as NSString).appendingPathComponent(".claude")
        let xd = codexDir ?? env["CODEX_HOME"] ?? (home as NSString).appendingPathComponent(".codex")
        self.claudeSettingsPaths = [(cd as NSString).appendingPathComponent("settings.json")]
        self.codexHookPaths = [(xd as NSString).appendingPathComponent("hooks.json"), (xd as NSString).appendingPathComponent("config.toml")]
        self.markers = markers
    }

    func fileContainsMarker(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 2 << 20), !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return false }
        return markers.contains { text.contains($0) }
    }

    public func claudeInstalled() -> Bool { claudeSettingsPaths.contains(where: fileContainsMarker) }
    public func codexInstalled() -> Bool { codexHookPaths.contains(where: fileContainsMarker) }

    public func state() -> HooksState {
        let c = claudeInstalled(), x = codexInstalled()
        return (c || x) ? .installed(claude: c, codex: x) : .notInstalled
    }
}
