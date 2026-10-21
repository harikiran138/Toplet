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

/// Merges Atoll's hooks into Claude Code's USER settings: `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`.
///
/// Never touches: project settings (`.claude/settings*.json`), managed settings (read-only warning check only),
/// `statusLine`, `permissions`, `env` or any other key. See HooksFileEditor for the merge guarantees and limits.
///
/// Documented limits (also in docs/AI-AGENTS-HOOK-FORMATS.md):
/// - key ORDER and all values are preserved; only whitespace is normalised. A file Claude Code wrote itself
///   (JSON.stringify, 2 spaces) round-trips byte-for-byte.
/// - strict JSON only: comments or trailing commas make the file unparseable for Claude Code too, so Atoll refuses.
/// - duplicate keys (`"hooks"` twice) are refused rather than guessed at.
final class ClaudeSettingsEditor {
    static func configDirectory(environment: [String: String], home: URL) -> URL {
        if let v = environment["CLAUDE_CONFIG_DIR"], !v.isEmpty { return URL(fileURLWithPath: expandTilde(v, home: home)) }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    static func settingsPath(configDir: URL) -> String { configDir.appendingPathComponent("settings.json").path }

    let editor: HooksFileEditor

    init(settingsPath: String, entries: [HookCommand.Entry], managedSettingsPath: String?, now: @escaping () -> Date = Date.init) {
        let notes = [
            "Claude Code holds hooks back in a folder until you accept its workspace trust dialog for that folder.",
            "Claude Code watches settings files and reloads hooks in running sessions; if a session does not report, restart it.",
        ]
        editor = HooksFileEditor(agent: .claudeCode, path: settingsPath, entries: entries, notes: notes,
                                 documentWarnings: { root in ClaudeSettingsEditor.warnings(root: root, path: settingsPath, managedSettingsPath: managedSettingsPath) },
                                 now: now)
    }

    func plan(_ mode: HooksFileEditor.Mode) throws -> HooksFileEditor.Plan { try editor.plan(mode) }
    func commit(_ plan: HooksFileEditor.Plan) throws -> HookFileChange { try editor.commit(plan) }
    func inspect() -> AgentHookState { editor.inspect() }

    /// `disableAllHooks` / `allowManagedHooksOnly`: Atoll still installs, but says that nothing will run.
    static func warnings(root: JSONValue, path: String, managedSettingsPath: String?) -> [String] {
        var w = [String]()
        if let members = root.objectValue {
            if case .bool(true)? = members.first(key: "disableAllHooks") {
                w.append("\(path) sets \"disableAllHooks\": true, so Claude Code runs no hooks at all (including Toplet's) until it is removed or set to false.")
            }
            if case .bool(true)? = members.first(key: "allowManagedHooksOnly") {
                w.append("\(path) sets \"allowManagedHooksOnly\": true. That key is meaningful only in managed settings; check whether your organisation blocks user hooks.")
            }
        }
        if let m = managedSettingsPath, let data = try? Data(contentsOf: URL(fileURLWithPath: m)),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if obj["allowManagedHooksOnly"] as? Bool == true {
                w.append("Managed policy (\(m)) sets allowManagedHooksOnly: Claude Code ignores user hooks, so Toplet's hooks will NOT run.")
            }
            if obj["disableAllHooks"] as? Bool == true {
                w.append("Managed policy (\(m)) sets disableAllHooks: Claude Code runs no hooks, so Toplet's hooks will NOT run.")
            }
        }
        return w
    }
}

func expandTilde(_ p: String, home: URL) -> String {
    if p == "~" { return home.path }
    if p.hasPrefix("~/") { return home.path + "/" + p.dropFirst(2) }
    return p
}
