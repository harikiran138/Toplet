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
import AppKit

// Settings for notch notifications, written as the CONTENT of a Form (grouped style, like every other Atoll settings page):
// the host drops `NotificationsSettingsSection(...)` into its settings Form (LiveActivitiesSettings). The settings value is a
// Binding (the host maps it to Defaults or to NotchNotificationCenter.settings); everything else is a closure.

enum NotificationsCopy {
    static let masterDetail = "Off by default. While off, nothing is received, queued or shown, and Toplet does not listen for anything."
    static let cannotSee = "macOS gives apps no way to observe or read other apps' notifications. Toplet therefore cannot show banners from Messages, Mail, Slack or any other app, and it does not try: no Notification Center scraping, no reading of its database, no Accessibility tricks. Those apps keep showing their own banners as usual."
    static let privacy = "Privacy is applied before anything is stored or shown. Notification text stays in memory only: it is never written to disk or broadcast to other apps."
    static let cliUsage = """
    atoll-notify --title "Build finished" --body "214 tests passed" --priority high
    atoll-notify --title "Deploy failed" --priority critical --open https://ci.example.com/run/42
    """
    static let cliDetail = "Run it from Terminal, a git hook, cron or CI. It talks to Toplet through a private socket in your home folder; only processes running as you can post. Nothing goes over the network."

    static func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

extension NotificationPrivacyMode {
    var title: String {
        switch self {
        case .off: return "Off"
        case .hidePreview: return "Hide preview"
        case .hideAll: return "Hide everything"
        }
    }
    var detail: String {
        switch self {
        case .off: return "Shows the app, title, and a two-line preview."
        case .hidePreview: return "Shows the app and title. The preview is replaced by \"Content hidden\"."
        case .hideAll: return "Shows only \"Notification from <app>\". Nothing the sender wrote is displayed."
        }
    }
}

extension NotificationFocusPolicy {
    var title: String {
        switch self {
        case .show: return "Always show"
        case .silence: return "Silence all"
        case .silenceExceptCritical: return "Silence, except critical"
        }
    }
    var detail: String {
        switch self {
        case .show: return "Focus and Do Not Disturb are ignored."
        case .silence: return "While a Focus is active nothing is shown. Notifications are kept in History."
        case .silenceExceptCritical: return "While a Focus is active only critical notifications are shown. The rest go to History."
        }
    }
}

extension NotificationSource {
    var title: String {
        switch self {
        case .atoll: return "Toplet itself"
        case .cli: return "atoll-notify command"
        case .extensionApp: return "Extension apps"
        case .agentClaude: return "Claude Code"
        case .agentCodex: return "Codex"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        }
    }
    var symbol: String {
        switch self {
        case .atoll: return "sparkles"
        case .cli: return "terminal"
        case .extensionApp: return "puzzlepiece.extension"
        case .agentClaude: return "sparkle"
        case .agentCodex: return "chevron.left.forwardslash.chevron.right"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        }
    }
    var detail: String {
        switch self {
        case .atoll: return "Messages Toplet's own features produce, such as update and permission notices. Nothing from other apps."
        case .cli: return "What you or your scripts post from Terminal: builds, git hooks, cron, CI. Only processes running as you can post."
        case .extensionApp: return "Apps you authorised through Toplet's extension API. Each app only sends what it chooses to."
        case .agentClaude: return "Approval requests and finished or failed runs, through the hooks you install in the Agents section."
        case .agentCodex: return "Approval requests and finished or failed runs, through the hooks you install in the Agents section."
        case .calendar: return "Event alerts from the calendars you gave Toplet access to. Toplet does not read the Calendar app's own notifications."
        case .reminders: return "Due reminders from the lists you gave Toplet access to."
        }
    }
}

@MainActor
final class NotificationsSettingsState: ObservableObject {
    @Published var copied = false
    private var resetWork: DispatchWorkItem?

    func didCopy() {
        copied = true
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copied = false }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

struct NotificationsSettingsSection: View {
    @Binding var settings: NotificationSettings
    var history: [NotificationHistoryEntry] = []
    var onSendTest: () -> Void = {}
    var onClearHistory: () -> Void = {}
    var cliUsage: String = NotificationsCopy.cliUsage
    var onCopy: (String) -> Void = NotificationsCopy.copyToPasteboard
    /// "Now" for the history times (injectable so snapshots are deterministic).
    var now: Date = Date()

    @StateObject private var state = NotificationsSettingsState()

    var body: some View {
        Group {
            generalSection
            if settings.enabled {
                limitsSection
                privacySection
                focusSection
                sourcesSection
            }
            visibilitySection
            if settings.enabled {
                testSection
                historySection
            }
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section {
            Toggle(isOn: $settings.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show notifications in the notch")
                    Text(verbatim: NotificationsCopy.masterDetail)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Notifications")
        }
    }

    // MARK: Limits

    private var limitsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Default duration")
                    Spacer()
                    Text(verbatim: "\(Int(settings.defaultDuration)) s").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.defaultDuration, in: 2...15, step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text(verbatim: "2 s").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text(verbatim: "15 s").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Default duration")
                .accessibilityValue("\(Int(settings.defaultDuration)) seconds")
                Text("How long a notification stays when its sender gives no time. Hovering over it pauses the countdown.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Stepper(value: $settings.maxQueue, in: 1...10) {
                HStack {
                    Text("Waiting queue")
                    Spacer()
                    Text(verbatim: "\(settings.maxQueue)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text("How many notifications may wait behind the one on screen. Extra ones go to History.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Stepper(value: $settings.dedupeWindow, in: 0...60, step: 5) {
                HStack {
                    Text("Repeat window")
                    Spacer()
                    Text(verbatim: settings.dedupeWindow <= 0 ? "Off" : "\(Int(settings.dedupeWindow)) s").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text("An identical notification from the same sender inside this window replaces the earlier one instead of stacking.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Stepper(value: $settings.rateLimitPerMinute, in: 5...120, step: 5) {
                HStack {
                    Text("Rate limit")
                    Spacer()
                    Text(verbatim: "\(settings.rateLimitPerMinute) per minute").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Timing and limits")
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Picker("Privacy", selection: $settings.privacyMode) {
                ForEach(NotificationPrivacyMode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            ForEach(NotificationPrivacyMode.allCases, id: \.self) { mode in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: mode == settings.privacyMode ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(mode == settings.privacyMode ? NotchUITheme.accent : Color.secondary)
                        .accessibilityHidden(true)
                    (Text(verbatim: mode.title).fontWeight(.medium) + Text(verbatim: "  " + mode.detail).foregroundStyle(.secondary))
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            NotificationPrivacyLivePreview(mode: settings.privacyMode)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            Label {
                Text(verbatim: NotificationsCopy.privacy).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
            }
        } header: {
            Text("Privacy")
        }
    }

    // MARK: Focus

    private var focusSection: some View {
        Section {
            Picker("While a Focus is active", selection: $settings.focusPolicy) {
                ForEach(NotificationFocusPolicy.allCases, id: \.self) { p in Text(verbatim: p.title).tag(p) }
            }
            Text(verbatim: settings.focusPolicy.detail)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Focus and Do Not Disturb")
        }
    }

    // MARK: Sources

    private func sourceBinding(_ s: NotificationSource) -> Binding<Bool> {
        Binding(get: { settings.enabledSources.contains(s) },
                set: { on in if on { settings.enabledSources.insert(s) } else { settings.enabledSources.remove(s) } })
    }

    private var sourcesSection: some View {
        Section {
            ForEach(NotificationSource.allCases, id: \.self) { s in
                Toggle(isOn: sourceBinding(s)) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: s.symbol).symbolRenderingMode(.hierarchical).frame(width: 18).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: s.title)
                            Text(verbatim: s.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text("A source that is switched off is dropped before it reaches the queue.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Sources")
        }
    }

    // MARK: What Atoll can and cannot see

    private var visibilitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("What Toplet cannot see").font(.subheadline.weight(.semibold))
                        Text(verbatim: NotificationsCopy.cannotSee)
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "eye.slash").symbolRenderingMode(.hierarchical).foregroundStyle(NotchUITheme.attention)
                }
                Divider()
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("What Toplet can show").font(.subheadline.weight(.semibold))
                        Text("Only these supported sources, each one switchable above:")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(NotificationSource.allCases, id: \.self) { s in
                            Text(verbatim: "\u{2022}  " + s.title).font(.caption)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle").symbolRenderingMode(.hierarchical).foregroundStyle(NotchUITheme.success)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .notchGlass()
            .accessibilityElement(children: .combine)
        } header: {
            Text("What Toplet can and cannot see")
        }
    }

    // MARK: Test + CLI

    private var testSection: some View {
        Section {
            HStack {
                Text("Check how a notification looks with your settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Send test notification", action: onSendTest).notchSystemButton(prominent: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("atoll-notify").font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        onCopy(cliUsage)
                        state.didCopy()
                    } label: {
                        Label(state.copied ? "Copied" : "Copy", systemImage: state.copied ? "checkmark" : "doc.on.doc")
                    }
                    .notchSystemButton()
                    .accessibilityLabel("Copy atoll-notify usage")
                }
                Text(verbatim: cliUsage)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(verbatim: NotificationsCopy.cliDetail)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Test and command line")
        }
    }

    // MARK: History

    private let visibleHistory = 6

    private var historySection: some View {
        Section {
            if history.isEmpty {
                Text("Nothing yet. Notifications that were shown, held back by Focus, or over the queue limit appear here (kept in memory only, cleared when Toplet quits).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(history.prefix(visibleHistory)) { entry in
                    NotificationHistoryRow(entry: entry, now: now)
                }
                if history.count > visibleHistory {
                    Text(verbatim: "and \(history.count - visibleHistory) more").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Clear history", role: .destructive, action: onClearHistory).notchSystemButton()
                }
            }
        } header: {
            Text("History")
        }
    }
}

struct NotificationHistoryRow: View {
    let entry: NotificationHistoryEntry
    let now: Date

    var body: some View {
        let p = NotificationPresentation(entry.display)
        HStack(spacing: 10) {
            Image(systemName: p.symbol).symbolRenderingMode(.hierarchical).frame(width: 20)
                .foregroundStyle(entry.display.priority == .critical ? Color.red : entry.display.priority == .high ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: p.title).lineLimit(1)
                Text(verbatim: p.appName + " \u{00B7} " + entry.source.title + (p.showsContentHidden ? " \u{00B7} content hidden" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !entry.wasShown {
                Text("Not shown").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
            }
            Text(verbatim: Self.relative(entry.receivedAt, now: now)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    static func relative(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 10 { return "now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        return "\(s / 86_400) d ago"
    }
}

/// The real expanded card, scaled, with the sample notification redacted the way the chosen mode does it.
struct NotificationPrivacyLivePreview: View {
    let mode: NotificationPrivacyMode
    var scale: CGFloat = 0.85

    var body: some View {
        let display = NotificationPrivacyPreview.display(for: NotificationPrivacyPreview.sample, mode: mode)
        let size = NotificationExpandedLayout.size(closedHeight: 34, notchWidth: 185, hasButtons: true)
        NotificationSneakPeekView(
            presentation: NotificationPresentation(display), expansion: 1, queued: 0, closedHeight: 34, notchWidth: 185,
            supportsSnooze: false, isActive: false,
            motionOverride: NotchUIMotion(isActive: false, reduceMotion: true, tick: 0, frozenTime: 0))
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .scaleEffect(scale, anchor: .top)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview with privacy mode \(mode.title)")
            .accessibilityValue(NotificationPresentation(display).accessibilityLabel)
    }
}

/// Convenience host: edits a `NotificationPresenting` center directly.
struct NotificationsSettingsSectionHost<Center: NotificationPresenting>: View {
    @ObservedObject var center: Center

    var body: some View {
        NotificationsSettingsSection(
            settings: Binding(get: { center.settings }, set: { center.settings = $0 }),
            history: center.history,
            onSendTest: { center.sendTestNotification() },
            onClearHistory: { center.clearHistory() })
    }
}
