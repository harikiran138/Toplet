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

// Small reusable pieces shared by the notch view and the settings section.

// MARK: - One shared 1 s clock

/// Drives the single `TimelineView` of the section (0.4 s steps, see AgentsMotion.swift). While `active` is false (notch
/// closed, nothing with a clock on screen) it yields exactly one entry, so no timer keeps running and nothing re-renders.
struct AgentsTickSchedule: TimelineSchedule {
    var active: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard active else { return AnySequence([startDate]) }
        let step = AgentsMotionEnvironment.tickInterval
        let first = Date(timeIntervalSinceReferenceDate: (startDate.timeIntervalSinceReferenceDate / step).rounded(.down) * step)
        return AnySequence(sequence(first: first) { $0.addingTimeInterval(step) })
    }
}

// MARK: - Buttons

struct AgentsButtonStyle: ButtonStyle {
    enum Kind { case primary, destructive, quiet, link }
    var kind: Kind = .quiet
    var prominentTint: Color = AgentsTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        AgentsStyledButton(configuration: configuration, kind: kind, tint: prominentTint)
    }
}

/// 28 pt round icon button. `glass: true` is a standalone Liquid Glass control (header); the default is a flat inset
/// for buttons that live inside a glass card.
struct AgentsIconButton: View {
    let systemName: String
    let label: String
    var glass = false
    var tint: Color = Color.primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: AgentsTheme.minTarget, height: AgentsTheme.minTarget)
                .modifier(IconSurface(glass: glass))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private struct IconSurface: ViewModifier {
        let glass: Bool
        func body(content: Content) -> some View {
            if glass {
                content.agentsGlass(shape: .circle, interactive: true)
            } else {
                content.agentsInset(shape: .circle)
            }
        }
    }
}

// MARK: - Badges and chips

struct AgentBadge: View {
    let kind: AgentKind
    var body: some View {
        let c = AgentsTheme.color(for: kind)
        Text(verbatim: kind.displayName)
            .font(.system(size: 9.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(c)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .agentsInset(tint: c, shape: .capsule)
            .fixedSize()
    }
}

struct AgentGlyph: View {
    let kind: AgentKind
    var size: CGFloat = 18
    var body: some View {
        let c = AgentsTheme.color(for: kind)
        Image(systemName: AgentsTheme.symbol(for: kind))
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(c)
            .frame(width: size, height: size)
            .agentsInset(tint: c, shape: .rounded(size * 0.3))
            .accessibilityHidden(true)
    }
}

private struct ChipSurface: ViewModifier {
    let tint: Color
    let filled: Bool
    func body(content: Content) -> some View {
        if filled { content.agentsInset(tint: tint, shape: .capsule) } else { content }
    }
}

struct AgentsChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = Color.secondary
    var filled = true

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)) }
            Text(verbatim: text).font(.system(size: 10, weight: .semibold)).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .modifier(ChipSurface(tint: tint, filled: filled))
        .fixedSize()
    }
}

struct SectionLabel: View {
    let title: String
    var count: Int?
    var tint: Color = Color.secondary

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
            if let count {
                Text(verbatim: "\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .opacity(0.8)
            }
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Banner

struct AgentsBanner: View {
    let systemImage: String
    let tint: Color
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                if let detail {
                    Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(AgentsButtonStyle(kind: .primary, prominentTint: tint))
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: AgentsTheme.minTarget, height: AgentsTheme.minTarget).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .agentsGlass(tint: tint)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Folder picker (default for the `pickProjectFolder` closure; the host may inject its own)

enum AgentsFolderPicker {
    @MainActor
    static func pick() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder the agent should work in"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Test hook: which session rows are currently realised

struct AgentsRowIDsKey: PreferenceKey {
    static var defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) { value.formUnion(nextValue()) }
}


// MARK: - Menu that degrades to its label in snapshot (ImageRenderer) mode

/// ImageRenderer draws AppKit-backed Menus as a "prohibited" placeholder, so test snapshots show the label only.
struct AgentsMenu<Label: View, Items: View>: View {
    @ViewBuilder var items: () -> Items
    @ViewBuilder var label: () -> Label

    var body: some View {
        if AgentsSurfaceConfig.snapshotStatic {
            label()
        } else {
            Menu { items() } label: { label() }
        }
    }
}

// MARK: - Clipboard

enum AgentsClipboard {
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - SHIM for the "finished since you last looked" state
//
// Core is adding `AgentSession.hasUnseenCompletion`, `AgentCenter.acknowledge(_:)`, `acknowledgeAll()` and
// `unseenCompletionCount`. Until they land the UI reads this single computed property. INTEGRATION: replace the body of
// `uiFinishedUnseen` with `hasUnseenCompletion` (one line); until then it is driven by `AgentsUnseenFixture` (fixtures only).

enum AgentsUnseenFixture {
    nonisolated(unsafe) static var ids: Set<String> = []
}

extension AgentSession {
    /// FIXTURE-ONLY until Core lands `hasUnseenCompletion`.
    var uiFinishedUnseen: Bool { AgentsUnseenFixture.ids.contains(id) }
}

extension AgentsFormat {
    /// "claude-sonnet-4-6" -> "sonnet 4.6", "claude-opus-4" -> "opus 4", "gpt-5-codex" -> "gpt-5 codex".
    static func modelTag(_ raw: String) -> String {
        var parts = raw.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        parts = parts.filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) && $0 != "latest" }       // drop date stamps
        if parts.count >= 2, parts[0] == "gpt", parts[1].allSatisfy({ $0.isNumber || $0 == "." }) {     // "gpt-5-codex" -> "gpt-5 codex"
            let head = parts[0] + "-" + parts[1]
            return ([head] + parts.dropFirst(2)).joined(separator: " ")
        }
        var digits: [String] = []
        while let last = parts.last, last.count <= 2, last.allSatisfy(\.isNumber) { digits.insert(parts.removeLast(), at: 0) }
        let name = parts.joined(separator: " ")
        let version = digits.joined(separator: ".")
        let tag = [name, version].filter { !$0.isEmpty }.joined(separator: " ")
        return tag.isEmpty ? raw : tag
    }
}
