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

// Fixtures for the notch notification UI snapshot harness (AtollNotch/Tests/run_notch_ui.sh).

/// A `NotificationPresenting` implementation the harness drives by hand. This is exactly the surface the real
/// NotchNotificationCenter has to provide.
@MainActor
final class FixtureNotificationCenter: NotificationPresenting {
    @Published var current: NotificationDisplay?
    @Published var queuedCount: Int = 0
    @Published var history: [NotificationHistoryEntry] = []
    @Published var settings = NotificationSettings()
    @Published var countdown: NotificationCountdown?
    var supportsSnooze = false

    private(set) var dismissed: [UUID] = []
    private(set) var performed: [UUID] = []
    private(set) var snoozed: [UUID] = []
    private(set) var hoverEvents: [Bool] = []
    private(set) var testSent = 0
    private(set) var historyCleared = 0

    init(current: NotificationDisplay? = nil, queued: Int = 0) {
        self.current = current
        self.queuedCount = queued
    }

    func dismiss(_ id: UUID) { dismissed.append(id); if current?.id == id { current = nil } }
    func performAction(_ id: UUID) { performed.append(id); if current?.id == id { current = nil } }
    func setHovering(_ hovering: Bool) { hoverEvents.append(hovering) }
    func snooze(_ id: UUID) { snoozed.append(id) }
    func clearHistory() { historyCleared += 1; history = [] }
    func sendTestNotification() { testSent += 1 }
}

let fixtureNow = Date()
func fixtureAgo(_ s: TimeInterval) -> Date { fixtureNow.addingTimeInterval(-s) }

func display(app: String = "Terminal", symbol: String? = "terminal.fill", title: String, subtitle: String? = nil, body: String? = nil,
             redacted: Bool = false, priority: NotificationPriority = .normal, action: Bool = true) -> NotificationDisplay {
    NotificationDisplay(id: UUID(), appName: app, iconSymbol: symbol, bundleID: nil, title: title, subtitle: subtitle, body: body,
                        isRedacted: redacted, priority: priority, hasAction: action)
}

enum NF {
    static let short = display(title: "Build finished", subtitle: "api-gateway", body: "All 214 tests passed in 3m 12s.")
    static let longTitle = "Production deploy of api-gateway v2.14.0 finished with 2 warnings in 3 regions"
    static let long = display(app: "CI", symbol: "checkmark.seal.fill", title: longTitle, subtitle: "production",
                              body: "Rollout is live in eu-west, us-east and ap-south. Two health checks reported slow responses during the canary stage and were retried automatically; no action is needed unless the error budget alerts fire again within the hour.")
    static let noIcon = display(app: "Reminders", symbol: nil, title: "Call the dentist", body: "Before 5 pm")
    static let noSymbolBogus = display(app: "Script", symbol: "this.symbol.does.not.exist", title: "Backup done", body: "Nightly backup completed.")
    static func priority(_ p: NotificationPriority) -> NotificationDisplay {
        display(app: "Monitor", symbol: p == .critical ? "exclamationmark.triangle.fill" : "waveform.path.ecg",
                title: "Disk usage on build-04: \(p)", body: "Used 91% of 1 TB. Cleanup job has not run in 6 days.", priority: p)
    }
    static let redacted = display(app: "Mail", symbol: "envelope.fill", title: "New message", redacted: true)
    static let noAction = display(title: "Backup completed", body: "No action needed.", action: false)
    static let critical = display(app: "Monitor", symbol: "exclamationmark.triangle.fill", title: "Database primary is unreachable",
                                  body: "Failover has not completed. 3 services are degraded.", priority: .critical)
}

func historyFixture() -> [NotificationHistoryEntry] {
    func e(_ d: NotificationDisplay, _ src: NotificationSource, _ ago: TimeInterval, shown: Bool = true) -> NotificationHistoryEntry {
        NotificationHistoryEntry(id: d.id, display: d, source: src, receivedAt: fixtureAgo(ago), wasShown: shown)
    }
    return [
        e(NF.short, .cli, 12),
        e(NF.redacted, .extensionApp, 95, shown: false),
        e(NF.critical, .agentClaude, 240),
        e(NF.noIcon, .reminders, 1800),
        e(display(app: "Codex", symbol: "chevron.left.forwardslash.chevron.right", title: "Needs your approval", redacted: true), .agentCodex, 5400),
        e(NF.long, .cli, 8000, shown: false),
        e(NF.noAction, .atoll, 90_000),
    ]
}
