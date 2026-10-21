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

/// Merges Atoll's hooks into Codex's USER hooks file: `$CODEX_HOME/hooks.json`, else `~/.codex/hooks.json`.
///
/// Why hooks.json and never config.toml: no TOML parser is available and a rewrite could destroy the user's config.
/// `hooks.json` is plain JSON with the same shape as Claude's (verified), so the same safe merge engine applies.
/// `config.toml` is only READ (line scan) to emit warnings; Atoll never writes it.
///
/// TRUST: Codex runs a non-managed hook only after the user reviews it with `/hooks`; trust is tied to the hook's
/// hash, so any byte change in Atoll's command makes Codex skip it until re-reviewed. Hence HookCommand's
/// byte-stability rule. The report tells the user to run /hooks once (`HookInstaller.codexTrustNote`).
final class CodexHooksEditor {
    static func codexHome(environment: [String: String], home: URL) -> URL {
        if let v = environment["CODEX_HOME"], !v.isEmpty { return URL(fileURLWithPath: expandTilde(v, home: home)) }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    static func hooksPath(codexHome: URL) -> String { codexHome.appendingPathComponent("hooks.json").path }
    static func configTomlPath(codexHome: URL) -> String { codexHome.appendingPathComponent("config.toml").path }

    let editor: HooksFileEditor

    init(hooksPath: String, configTomlPath: String?, entries: [HookCommand.Entry], now: @escaping () -> Date = Date.init) {
        editor = HooksFileEditor(agent: .codex, path: hooksPath, entries: entries, notes: [HookInstaller.codexTrustNote],
                                 documentWarnings: { _ in configTomlPath.map { CodexHooksEditor.scanConfigToml(path: $0) } ?? [] },
                                 now: now)
    }

    func plan(_ mode: HooksFileEditor.Mode) throws -> HooksFileEditor.Plan { try editor.plan(mode) }
    func commit(_ plan: HooksFileEditor.Plan) throws -> HookFileChange { try editor.commit(plan) }
    func inspect() -> AgentHookState { editor.inspect() }

    /// READ-ONLY line scan of config.toml (no TOML parser; never written):
    /// - inline `[hooks...]` / `[[hooks...]]` tables next to hooks.json: Codex merges both and prints a startup warning
    ///   (the docs recommend one representation per layer)
    /// - `[features]` with `hooks = false` (or the deprecated alias `codex_hooks = false`): Codex runs no hooks
    static func scanConfigToml(path: String) -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count < 8 * 1024 * 1024 else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var warnings = [String]()
        var table = ""
        var inline = false, disabled = false
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("[") {
                var t = line
                if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]).trimmingCharacters(in: .whitespaces) }
                t = t.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                table = t
                if t == "hooks" || t.hasPrefix("hooks.") { inline = true }
                continue
            }
            if table == "features" {
                let compact = line.replacingOccurrences(of: " ", with: "")
                if compact.hasPrefix("hooks=false") || compact.hasPrefix("codex_hooks=false") { disabled = true }
            }
            if table.isEmpty, line.replacingOccurrences(of: " ", with: "").hasPrefix("hooks=") { inline = true }  // inline-table form `hooks = {...}` at root
        }
        if inline {
            warnings.append("\(path) also defines inline [hooks]. Codex merges hooks.json with inline hooks and prints a startup warning; its docs recommend one representation per layer. Toplet does not edit config.toml.")
        }
        if disabled {
            warnings.append("\(path) sets [features] hooks = false, so Codex runs no hooks (including Toplet's).")
        }
        return warnings
    }
}
