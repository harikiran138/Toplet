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

import SwiftUI

// Settings for the Agents feature, written as the CONTENT of a Form (grouped style, like the other Atoll settings
// pages): the host drops `AgentsSettingsSection(...)` into its settings Form. The master toggle and the approval timeout
// are owned by the host (Defaults) and arrive as Bindings; everything else goes straight to AgentCenter.

/// All user-facing statements about what the installer touches live here so they can be kept in sync with the real
/// HookInstaller in one place. Nothing in this file edits any file; the buttons only call `AgentCenter`.
enum AgentsCopy {
    static let claudeFile = "~/.claude/settings.json"
    static let codexFile = "~/.codex/hooks.json"
    static let claudeWhat = "Adds Toplet-marked hook entries to the \"hooks\" section. Your other settings and hooks are left as they are."
    static let codexWhat = "Adds Toplet-marked hook entries. Your other Codex configuration is left as it is."
    static let safety = [
        "Nothing is changed until you press Install.",
        "Each file is backed up next to the original (timestamped) before it is edited, and written atomically.",
        "Toplet's entries carry a marker, so Uninstall removes exactly those entries and nothing else.",
        "If a file cannot be parsed, Toplet refuses to touch it.",
        "Hooks fail open: if Toplet is not running, your agents behave exactly as without it."
    ]
    static let codexTrust = "Codex asks you to review new hooks once. After installing, run /hooks inside Codex and trust the Toplet entry; until then Codex ignores it."
    static let privacy = "Local only. Toplet talks to your agents through a private socket in your home folder (no network port), reads their local session files, and stores your board on this Mac. No network requests, no telemetry, nothing leaves your Mac."
}

@MainActor
final class AgentsSettingsState: ObservableObject {
    @Published var installClaude = true
    @Published var installCodex = true
    @Published var showPreview = false
    @Published var previewText = ""
    @Published var confirmInstall = false
    @Published var confirmUninstall = false
}

struct AgentsSettingsSection: View {
    @ObservedObject var center: AgentCenter
    @Binding var isEnabled: Bool
    @Binding var approvalTimeoutSeconds: Int
    var timeoutRange: ClosedRange<Int> = 15...600
    var timeoutStep: Int = 15

    @StateObject private var state = AgentsSettingsState()

    var body: some View {
        Group {
            generalSection
            if isEnabled {
                statusSection
                hooksSection
                approvalsSection
            }
            privacySection
        }
        .sheet(isPresented: $state.showPreview) {
            HookPreviewSheet(text: state.previewText) {
                state.showPreview = false
            }
        }
        .confirmationDialog("Install Toplet hooks?", isPresented: $state.confirmInstall, titleVisibility: .visible) {
            Button("Install") { center.installHooks(claude: state.installClaude, codex: state.installCodex) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(installSummary)
        }
        .confirmationDialog("Remove Toplet hooks?", isPresented: $state.confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { center.uninstallHooks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the entries Toplet added (marked) are removed. Live status and approvals stop; passive discovery keeps working.")
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show AI coding agents in the notch")
                    Text("Claude Code and Codex sessions, approvals and your own task board. Off by default: while off, nothing runs (no socket, no scanning).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Agents")
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            LabeledContent("Live channel") {
                HStack(spacing: 6) {
                    Circle().fill(channelColor).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(verbatim: channelText).foregroundStyle(.secondary)
                }
            }
            if let error = center.serverError, !error.isEmpty {
                Text(verbatim: error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Hooks") {
                HStack(spacing: 6) {
                    Circle().fill(hooksColor).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(verbatim: hooksText).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Sessions found") {
                HStack(spacing: 10) {
                    Text(verbatim: "\(center.sessions.count)").monospacedDigit().foregroundStyle(.secondary)
                    Button("Refresh discovery") { center.refreshDiscovery() }.agentsSystemButton()
                }
            }
        } header: {
            Text("Status")
        }
    }

    private var channelText: String {
        if let e = center.serverError, !e.isEmpty { return "Unavailable" }
        return center.isRunning ? "Running" : "Stopped"
    }

    private var channelColor: Color {
        if let e = center.serverError, !e.isEmpty { return .orange }
        return center.isRunning ? .green : .gray
    }

    private var hooksText: String {
        switch center.hooksState {
        case .notInstalled: return "Not installed"
        case .installed(let claude, let codex):
            switch (claude, codex) {
            case (true, true): return "Installed for Claude Code and Codex"
            case (true, false): return "Installed for Claude Code"
            case (false, true): return "Installed for Codex"
            case (false, false): return "Not installed"
            }
        case .error(let m): return "Problem: " + m
        }
    }

    private var hooksColor: Color {
        switch center.hooksState {
        case .notInstalled: return .gray
        case .installed(let c, let x): return (c || x) ? .green : .gray
        case .error: return .red
        }
    }

    private var hooksInstalledAny: Bool {
        if case .installed(let c, let x) = center.hooksState { return c || x }
        return false
    }

    // MARK: Hooks

    private var hooksSection: some View {
        Section {
            Text("Hooks give live status (current tool, subagents) and let you approve tool calls from the notch. They are optional: without them Toplet still shows sessions it finds passively.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $state.installClaude) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code")
                    Text(verbatim: "Edits \(AgentsCopy.claudeFile). \(AgentsCopy.claudeWhat)")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $state.installCodex) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex")
                    Text(verbatim: "Edits \(AgentsCopy.codexFile). \(AgentsCopy.codexWhat)")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(AgentsCopy.safety, id: \.self) { line in
                    Label {
                        Text(verbatim: line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.circle").symbolRenderingMode(.hierarchical).font(.caption).foregroundStyle(.green)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentsGlass(tint: AgentsTheme.success, shape: .rounded(AgentsTheme.cardRadius))

            HStack(spacing: 10) {
                AgentsGlassGroup(spacing: 12) {
                    HStack(spacing: 12) {
                        Button("Preview changes…") {
                            state.previewText = center.previewHookChanges()
                            state.showPreview = true
                        }
                        .agentsSystemButton()
                        .disabled(!state.installClaude && !state.installCodex)
                        Button("Install hooks…") { state.confirmInstall = true }
                            .agentsSystemButton(prominent: true)
                            .disabled(!state.installClaude && !state.installCodex)
                    }
                }
                Spacer()
                Button("Uninstall hooks…", role: .destructive) { state.confirmUninstall = true }
                    .agentsSystemButton()
                    .disabled(!hooksInstalledAny)
            }

            Label {
                Text(AgentsCopy.codexTrust).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").symbolRenderingMode(.hierarchical).foregroundStyle(AgentsTheme.color(for: .codex))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentsGlass(tint: AgentsTheme.color(for: .codex), shape: .rounded(AgentsTheme.cardRadius))
        } header: {
            Text("Hooks")
        }
    }

    private var installSummary: String {
        var files: [String] = []
        if state.installClaude { files.append(AgentsCopy.claudeFile) }
        if state.installCodex { files.append(AgentsCopy.codexFile) }
        return "Toplet will back up and then edit: " + files.joined(separator: ", ") + ". You can remove its entries again with Uninstall hooks."
    }

    // MARK: Approvals

    private var approvalsSection: some View {
        Section {
            Stepper(value: $approvalTimeoutSeconds, in: timeoutRange, step: timeoutStep) {
                HStack {
                    Text("Approval timeout")
                    Spacer()
                    Text(verbatim: "\(approvalTimeoutSeconds) s").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text("When a request is not answered in time Toplet lets the agent's own prompt decide. Nothing is ever approved automatically, and Allow buttons only appear for live, hook-verified sessions.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Approvals")
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Label {
                Text(AgentsCopy.privacy).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentsGlass()
        } header: {
            Text("Privacy")
        }
    }
}

// MARK: - Preview sheet

struct HookPreviewSheet: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hook changes preview").font(.headline)
            Text("What installing would change in your agents' configuration files, with a backup made first.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: text.isEmpty ? "No changes to show." : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 180)
            HStack {
                Text("This is a preview only. Nothing has been written.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 360)
    }
}
