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

// One toggle per integration that competes for the closed notch, each showing its READ-ONLY priority rank, plus a small
// diagram of the deterministic order. The ranks come from the table in docs/NOTIFICATIONS-IDLE-AUDIT.md section 2.7
// (`IntegrationPriorityTable.default`); the arbiter's contract can replace the rows through `rows`. This view never changes
// a rank: the order is fixed, only whether an integration takes part is the user's choice.

enum NotchIntegration: String, CaseIterable, Identifiable {
    case recordingPrivacy, battery, notifications, music, timersReminders, downloads, extensions, agents, idle
    var id: String { rawValue }
}

/// Priority classes of the audit's table (2.7).
enum IntegrationClass: String, CaseIterable {
    case structural, safety, transient, sticky, ambient

    var title: String {
        switch self {
        case .structural: return "Structural"
        case .safety: return "Safety"
        case .transient: return "Transient"
        case .sticky: return "Sticky"
        case .ambient: return "Ambient"
        }
    }
    var detail: String {
        switch self {
        case .structural: return "Screen state. Never preempted."
        case .safety: return "Privacy and critical. Preempts media."
        case .transient: return "Timed. Preempts, then resumes."
        case .sticky: return "Lives while its condition holds."
        case .ambient: return "Decorative. Always yields."
        }
    }
    var tint: Color {
        switch self {
        case .structural: return Color.gray
        case .safety: return Color.red
        case .transient: return Color.orange
        case .sticky: return Color.blue
        case .ambient: return Color.purple
        }
    }
}

struct IntegrationRowInfo: Identifiable, Equatable {
    var integration: NotchIntegration
    var title: String
    var symbol: String
    var detail: String
    /// Shown verbatim, e.g. "5 critical, 7 normal".
    var rankText: String
    /// Sort key (lowest = highest priority).
    var sortKey: Double
    var classes: [IntegrationClass]
    var id: String { integration.rawValue }
}

enum IntegrationPriorityTable {
    /// From docs/NOTIFICATIONS-IDLE-AUDIT.md 2.7, one row per user-facing integration, highest priority first.
    static let `default`: [IntegrationRowInfo] = [
        .init(integration: .recordingPrivacy, title: "Screen recording and privacy indicators", symbol: "record.circle",
              detail: "Camera and microphone indicators stay visible until the camera or mic stops.",
              rankText: "3 privacy, 12 recording", sortKey: 3, classes: [.safety, .sticky]),
        .init(integration: .battery, title: "Battery and charging", symbol: "battery.100.bolt",
              detail: "Charging, low battery and fully charged alerts.",
              rankText: "4", sortKey: 4, classes: [.transient]),
        .init(integration: .notifications, title: "Notifications", symbol: "bell.badge",
              detail: "Critical ones are never dropped; normal and high ones yield to system HUDs and resume afterwards.",
              rankText: "5 critical, 7 normal and high", sortKey: 5, classes: [.transient]),
        .init(integration: .music, title: "Music", symbol: "music.note",
              detail: "Now playing, with its secondary badge.",
              rankText: "9", sortKey: 9, classes: [.sticky]),
        .init(integration: .timersReminders, title: "Timers and reminders", symbol: "timer",
              detail: "Running timers and upcoming reminders.",
              rankText: "10 timer, 11 reminder", sortKey: 10, classes: [.sticky]),
        .init(integration: .downloads, title: "Downloads", symbol: "arrow.down.circle",
              detail: "Browser downloads in progress.",
              rankText: "13", sortKey: 13, classes: [.sticky]),
        .init(integration: .extensions, title: "Extension live activities", symbol: "puzzlepiece.extension",
              detail: "Live activities from apps you authorised.",
              rankText: "16", sortKey: 16, classes: [.sticky]),
        .init(integration: .agents, title: "AI agents", symbol: "sparkles",
              detail: "Claude Code and Codex sessions and approvals.",
              rankText: "assigned by the arbiter", sortKey: 16.5, classes: [.sticky]),
        .init(integration: .idle, title: "Idle animation", symbol: "moon.zzz",
              detail: "Decorative animation when nothing else is going on.",
              rankText: "18", sortKey: 18, classes: [.ambient]),
    ]
}

enum IntegrationsCopy {
    static let rule = "Higher rows interrupt lower rows; lower rows resume."
    static let detail = "The order is fixed and deterministic: it is the same on every Mac, and the same events always produce the same result. You choose which integrations take part; you cannot reorder them."
}

struct IntegrationsSettingsSection: View {
    /// Binding for each integration's on/off (the host maps these to Defaults).
    var isOn: (NotchIntegration) -> Binding<Bool>
    var rows: [IntegrationRowInfo] = IntegrationPriorityTable.default

    var body: some View {
        Group {
            Section {
                Label {
                    Text(verbatim: IntegrationsCopy.rule).font(.callout.weight(.medium))
                } icon: {
                    Image(systemName: "arrow.up.arrow.down").symbolRenderingMode(.hierarchical).foregroundStyle(NotchUITheme.accent)
                }
                Text(verbatim: IntegrationsCopy.detail)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(rows.sorted { $0.sortKey < $1.sortKey }) { row in
                    Toggle(isOn: isOn(row.integration)) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: row.symbol).symbolRenderingMode(.hierarchical).frame(width: 20).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(verbatim: row.title)
                                    Spacer(minLength: 8)
                                    Text(verbatim: "Rank " + row.rankText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Text(verbatim: row.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityHint("Priority rank " + row.rankText)
                }
            } header: {
                Text("Integrations")
            }
            Section {
                IntegrationOrderDiagram(rows: rows)
            } header: {
                Text("Order")
            }
        }
    }
}

/// Five classes from highest to lowest priority, with the integrations that live in each, and the two rules as arrows.
struct IntegrationOrderDiagram: View {
    var rows: [IntegrationRowInfo]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                Text("Higher interrupts lower").font(.caption)
                Spacer()
                Text("highest priority").font(.caption2).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                Text("lowest").font(.caption2).foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 6) {
                ForEach(IntegrationClass.allCases, id: \.self) { cls in
                    band(cls)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.left").font(.caption.weight(.semibold))
                Text("Lower resumes when the higher one ends").font(.caption)
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .notchGlass()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Priority order, highest first: " + IntegrationClass.allCases.map { cls in
            cls.title + (members(of: cls).isEmpty ? "" : " (" + members(of: cls).map(\.title).joined(separator: ", ") + ")")
        }.joined(separator: "; "))
    }

    private func members(of cls: IntegrationClass) -> [IntegrationRowInfo] {
        rows.filter { $0.classes.contains(cls) }.sorted { $0.sortKey < $1.sortKey }
    }

    private func band(_ cls: IntegrationClass) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: cls.title).font(.caption.weight(.semibold)).foregroundStyle(cls.tint)
            Text(verbatim: cls.detail).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if cls == .structural {
                Text("Connectivity, welcome").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            ForEach(members(of: cls)) { r in
                HStack(spacing: 4) {
                    Image(systemName: r.symbol).font(.system(size: 9)).frame(width: 12)
                    Text(verbatim: shortTitle(r, in: cls)).font(.system(size: 9.5)).lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .notchInset(tint: cls.tint, shape: .rounded(10))
    }

    private func shortTitle(_ r: IntegrationRowInfo, in cls: IntegrationClass) -> String {
        switch r.integration {
        case .recordingPrivacy: return cls == .safety ? "Privacy" : "Recording"
        case .timersReminders: return "Timers, reminders"
        case .extensions: return "Extensions"
        case .battery: return "Battery"
        case .downloads: return "Downloads"
        default: return r.title
        }
    }
}
