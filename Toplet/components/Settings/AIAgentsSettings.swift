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

import AppKit
import Defaults
import SwiftUI

/// Settings page "AI Agents" (Developer group). The master switch, hooks Install/Preview/Uninstall (explicit, nothing is
/// written until the user confirms), the approval timeout, status and the privacy note come from the standalone
/// `AgentsSettingsSection`; this view wires it to Atoll's Defaults and adds the display / discovery / terminal-jump options.
struct AIAgentsSettings: View {
    @ObservedObject private var runtime = AgentsRuntime.shared
    @Default(.enableAgentsFeature) private var enabled
    @Default(.agentsApprovalTimeoutSeconds) private var approvalTimeout
    @Default(.agentsPanelHeightFraction) private var panelHeightFraction

    private func highlightID(_ title: String) -> String { "aiAgents-\(title)" }

    var body: some View {
        Form {
            AgentsSettingsSection(
                center: runtime.center,
                isEnabled: $enabled,
                approvalTimeoutSeconds: $approvalTimeout,
                timeoutRange: 15...600
            )

            if enabled {
                Section {
                    Defaults.Toggle(key: .agentsPassiveDiscovery) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Discover running agent sessions")
                            Text("Finds Claude Code and Codex sessions that are already running by reading their local process list and session files, so they show up even without hooks (status is estimated). Changing this briefly restarts the live channel.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .settingsHighlight(id: highlightID("Discover running agent sessions"))

                    Defaults.Toggle(key: .agentsShowClosedIndicator) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show agents in the closed notch")
                            Text("A small glyph next to the notch while an agent is running, waiting for you or finished. Hidden when nothing is active, behind music and timers.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .settingsHighlight(id: highlightID("Show agents in the closed notch"))

                    Defaults.Toggle(key: .agentsNotifyOnFinish) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sound when an agent finishes")
                            Text("Plays a soft system sound when a session finishes while you are not looking at the Agents tab. Off by default.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .settingsHighlight(id: highlightID("Sound when an agent finishes"))

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Agents panel height")
                            Spacer()
                            Text("Up to \(Int((panelHeightFraction * 100).rounded()))% of screen · \(Int(AgentsNotchSizing.maximumHeight(screenName: nil))) pt")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $panelHeightFraction, in: AgentsNotchSizing.fractionRange, step: 0.05)
                        Text("The Agents tab grows to fit its sessions and board, up to this height; anything beyond it scrolls. It never goes below 240 pt or past the bottom of the screen.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .settingsHighlight(id: highlightID("Agents panel height"))
                } header: {
                    Text("Display and discovery")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Jumping from a session to its terminal or editor uses macOS Automation (Apple Events) for terminals such as Terminal and iTerm2. macOS asks once per app the first time you jump; you can review or revoke the permission in System Settings. Apps without scripting support are simply brought to the front.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Open Automation settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .settingsHighlight(id: highlightID("Terminal jumping permission"))
                } header: {
                    Text("Terminal jumping")
                }
            }
        }
        .navigationTitle("AI Agents")
    }
}
