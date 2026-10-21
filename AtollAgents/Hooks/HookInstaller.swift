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

/// Installs / previews / removes Atoll's hooks in the user's Claude Code and Codex configuration.
/// Explicit and reversible: nothing here runs unless the user asked for it; there is no helper binary and the
/// socket directory is created by the server, never by the installer.
public final class HookInstaller: HookInstalling {
    public static let codexTrustNote =
        "Codex runs non-managed hooks only after you review them: open Codex and run /hooks once to trust Toplet's hooks. "
        + "Until then Codex skips them. Trust is tied to each hook's hash, so if Toplet's hook command ever changes you will be asked to review it again."

    /// UNVERIFIED location (not re-fetched from the managed-settings docs): used only to WARN, never written.
    public static let defaultManagedClaudeSettingsPath = "/Library/Application Support/ClaudeCode/managed-settings.json"

    public let homeDirectory: URL
    public let claudeConfigDirectory: URL
    public let codexHomeDirectory: URL
    public let socketPath: String?
    let managedClaudeSettingsPath: String?
    let now: () -> Date

    public var claudeSettingsPath: String { ClaudeSettingsEditor.settingsPath(configDir: claudeConfigDirectory) }
    public var codexHooksPath: String { CodexHooksEditor.hooksPath(codexHome: codexHomeDirectory) }

    /// - Parameters:
    ///   - homeDirectory/environment: injectable for tests. Defaults read the real home and `CLAUDE_CONFIG_DIR` / `CODEX_HOME`.
    ///   - socketPath: nil = `$HOME/.atoll/run/agent.sock`; otherwise an absolute / `~/` / `$HOME/` path (validated on use).
    ///   - managedClaudeSettingsPath: read-only warning check; pass nil to skip.
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                socketPath: String? = nil,
                managedClaudeSettingsPath: String? = HookInstaller.defaultManagedClaudeSettingsPath,
                now: @escaping () -> Date = Date.init) {
        self.homeDirectory = homeDirectory
        self.claudeConfigDirectory = ClaudeSettingsEditor.configDirectory(environment: environment, home: homeDirectory)
        self.codexHomeDirectory = CodexHooksEditor.codexHome(environment: environment, home: homeDirectory)
        self.socketPath = socketPath
        self.managedClaudeSettingsPath = managedClaudeSettingsPath
        self.now = now
    }

    // MARK: Editors

    private func entries(_ agent: AgentKind) throws -> [HookCommand.Entry] {
        try HookCommand.entries(for: agent, socketPath: socketPath, home: homeDirectory.path)
    }
    private func claudeEditor() throws -> ClaudeSettingsEditor {
        ClaudeSettingsEditor(settingsPath: claudeSettingsPath, entries: try entries(.claudeCode),
                             managedSettingsPath: managedClaudeSettingsPath, now: now)
    }
    private func codexEditor() throws -> CodexHooksEditor {
        CodexHooksEditor(hooksPath: codexHooksPath, configTomlPath: CodexHooksEditor.configTomlPath(codexHome: codexHomeDirectory),
                         entries: try entries(.codex), now: now)
    }

    // MARK: State

    public func detailedState() -> HooksDetailedState {
        func st(_ make: () throws -> AgentHookState) -> AgentHookState { (try? make()) ?? .notInstalled }
        return HooksDetailedState(claude: st { try claudeEditor().inspect() }, codex: st { try codexEditor().inspect() })
    }

    public func state() -> HooksState {
        let d = detailedState()
        let c = d.claude == .installed, x = d.codex == .installed
        return (c || x) ? .installed(claude: c, codex: x) : .notInstalled
    }

    // MARK: Preview

    public func preview() -> String { preview(claude: true, codex: true) }

    public func preview(claude: Bool, codex: Bool) -> String {
        var out = "Toplet agent hooks (command version \(HookCommand.commandVersion)). Preview only: nothing has been written.\n"
        out += "Socket: \(socketPath ?? HookCommand.defaultSocketShellLiteral) (created by Toplet when the feature runs, not by this installer)\n"
        var anyChange = false
        var targets: [(String, () throws -> HooksFileEditor.Plan)] = []
        if claude { targets.append(("Claude Code", { try self.claudeEditor().plan(.install) })) }
        if codex { targets.append(("Codex", { try self.codexEditor().plan(.install) })) }
        for (name, makePlan) in targets {
            out += "\n== \(name) ==\n"
            do {
                let plan = try makePlan()
                let c = plan.change
                if let newText = plan.newText {
                    anyChange = true
                    let oldLabel = c.created ? "/dev/null" : c.path
                    out += HookDiff.unified(old: plan.originalText, new: newText, oldLabel: oldLabel, newLabel: c.path + (c.created ? " (new file)" : " (after install)"))
                    if !plan.snapshot.exists { out += "(file does not exist yet and would be created)\n" } else { out += "A timestamped backup \(c.path).atoll-backup-<time> would be written first (last \(HooksFileIO.backupsToKeep) kept).\n" }
                    if !c.added.isEmpty { out += "Adds \(c.added.count) hook entries: \(c.added.joined(separator: ", ")).\n" }
                    if !c.staleRemoved.isEmpty { out += "Replaces older Toplet entries on: \(c.staleRemoved.joined(separator: ", ")).\n" }
                } else {
                    out += "Nothing to change: \(c.path) already has all \(c.alreadyPresent.count) Toplet hook entries.\n"
                }
                for w in c.warnings { out += "WARNING: \(w)\n" }
                // the Codex trust note matters only when the hook definitions would actually change
                if c.agent != .codex || plan.newText != nil { for n in c.notes { out += "Note: \(n)\n" } }
            } catch {
                out += "Cannot change this file: \(error)\n"
            }
        }
        if !anyChange { out += "\nNothing to change.\n" }
        return out
    }

    // MARK: Install / uninstall

    /// Core's `HookInstalling` requirement (Void). Use `installWithReport` to get the details.
    public func install(claude: Bool, codex: Bool) throws { _ = try installWithReport(claude: claude, codex: codex) }

    /// Core's `HookInstalling` requirement (Void). Use `uninstallWithReport` to get the details.
    public func uninstall() throws { _ = try uninstallWithReport() }

    @discardableResult
    public func installWithReport(claude: Bool, codex: Bool) throws -> HookInstallReport {
        _ = try HookCommand.socketShellLiteral(socketPath, home: homeDirectory.path)   // validate first
        var steps: [(HooksFileEditor.Plan, (HooksFileEditor.Plan) throws -> HookFileChange)] = []
        if claude { let e = try claudeEditor(); steps.append((try e.plan(.install), e.commit)) }
        if codex { let e = try codexEditor(); steps.append((try e.plan(.install), e.commit)) }
        return try run(action: "install", steps: steps)
    }

    @discardableResult
    public func uninstallWithReport() throws -> HookInstallReport {
        var steps: [(HooksFileEditor.Plan, (HooksFileEditor.Plan) throws -> HookFileChange)] = []
        let c = try claudeEditor(), x = try codexEditor()
        steps.append((try c.plan(.uninstall), c.commit))
        steps.append((try x.plan(.uninstall), x.commit))
        return try run(action: "uninstall", steps: steps)
    }

    /// All files were parsed and checked (plan) before the first write; commit them in order.
    private func run(action: String, steps: [(HooksFileEditor.Plan, (HooksFileEditor.Plan) throws -> HookFileChange)]) throws -> HookInstallReport {
        var done = [HookFileChange]()
        for (plan, commit) in steps {
            do { done.append(try commit(plan)) }
            catch {
                let partial = report(action: action, files: done)
                if done.isEmpty { throw error }
                throw HookInstallError.partiallyApplied(report: partial, failedPath: plan.change.path, reason: "\(error)")
            }
        }
        return report(action: action, files: done)
    }

    private func report(action: String, files: [HookFileChange]) -> HookInstallReport {
        let trust = action == "install" && files.contains { $0.agent == .codex && ($0.wroteFile) }
        var summary = [String]()
        for f in files {
            let who = f.agent.displayName
            if action == "install" {
                if f.nothingToChange { summary.append("\(who): already up to date (\(f.alreadyPresent.count) entries), file untouched") }
                else { summary.append("\(who): added \(f.added.count) entries" + (f.staleRemoved.isEmpty ? "" : ", replaced \(f.staleRemoved.count) older Toplet entries") + (f.backupPath.map { ", backup at \($0)" } ?? "")) }
            } else {
                if f.nothingToChange { summary.append("\(who): no Toplet entries found, file untouched") }
                else { summary.append("\(who): removed Toplet entries from \(f.removed.count + f.staleRemoved.count) events" + (f.backupPath.map { ", backup at \($0)" } ?? "")) }
            }
        }
        var warnings = [String]()
        for f in files { warnings += f.warnings }
        if trust { warnings.append(HookInstaller.codexTrustNote) }
        return HookInstallReport(action: action, files: files, warnings: warnings, needsCodexTrustReview: trust, summary: summary.joined(separator: "\n"))
    }
}
