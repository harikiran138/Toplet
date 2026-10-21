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

// Shared data contract for notch notifications (see docs/NOTIFICATIONS-IDLE-AUDIT.md section 7).
// Pure value types, Foundation only. There is NO public macOS API for observing other apps' notifications, so
// every notification enters through a supported source below; nothing here scrapes Notification Center.

public enum NotificationPriority: Int, Codable, Sendable, Comparable, CaseIterable {
    case low = 0, normal = 1, high = 2, critical = 3
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Where a notification came from. Only supported, public mechanisms exist (see docs/NOTIFICATIONS-SOURCES.md).
public enum NotificationSource: String, Codable, Sendable, CaseIterable {
    case atoll              // Atoll's own UNUserNotificationCenter notifications
    case cli                // `atoll-notify` command / private unix socket (scripts, git hooks, CI, cron)
    case extensionApp       // third-party app through AtollExtensionKit (authorised)
    case agentClaude        // Claude Code via the AI-agents feature
    case agentCodex         // Codex via the AI-agents feature
    case calendar           // EventKit calendar alerts
    case reminders          // EventKit reminders
}

public enum NotificationAction: Codable, Sendable, Equatable {
    case none
    case openURL(URL)                 // http(s)/file/custom scheme chosen by the sender; validated before use
    case activateApp(bundleID: String)
    case openNotchTab(String)         // e.g. "agents"
    case openAgentSession(String)     // AgentSession.id
}

public enum NotificationPrivacyMode: String, Codable, Sendable, CaseIterable {
    case off            // show everything
    case hidePreview    // title + app only; body and subtitle hidden   (default)
    case hideAll        // generic 'Notification from <app>'
}

public enum NotificationFocusPolicy: String, Codable, Sendable, CaseIterable {
    case show                   // ignore Focus
    case silence                // drop non-critical while Focus/Do Not Disturb is active (kept in history, not shown)
    case silenceExceptCritical  // same, but .critical still shows                (default)
}

public struct NotchNotification: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var source: NotificationSource
    public var appName: String
    public var bundleID: String?
    public var iconSymbol: String?        // SF Symbol name; never an arbitrary image from the sender
    public var title: String
    public var subtitle: String?
    public var body: String?
    public var receivedAt: Date
    public var priority: NotificationPriority
    public var ttl: TimeInterval?         // nil = use the user's default duration
    public var dedupeKey: String?         // same key within the dedupe window replaces/ignores
    public var threadID: String?          // grouping hint
    public var action: NotificationAction
    public var isSensitive: Bool          // sender says content is sensitive: treated as hidePreview at least
    public init(id: UUID = UUID(), source: NotificationSource, appName: String, bundleID: String? = nil, iconSymbol: String? = nil,
                title: String, subtitle: String? = nil, body: String? = nil, receivedAt: Date = Date(),
                priority: NotificationPriority = .normal, ttl: TimeInterval? = nil, dedupeKey: String? = nil,
                threadID: String? = nil, action: NotificationAction = .none, isSensitive: Bool = false) {
        self.id = id; self.source = source; self.appName = appName; self.bundleID = bundleID; self.iconSymbol = iconSymbol
        self.title = title; self.subtitle = subtitle; self.body = body; self.receivedAt = receivedAt
        self.priority = priority; self.ttl = ttl; self.dedupeKey = dedupeKey; self.threadID = threadID
        self.action = action; self.isSensitive = isSensitive
    }
}

/// What the UI is allowed to show after privacy redaction. The UI never sees the raw text when it is redacted.
public struct NotificationDisplay: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var appName: String
    public var iconSymbol: String?
    public var bundleID: String?
    public var title: String
    public var subtitle: String?
    public var body: String?
    public var isRedacted: Bool
    public var priority: NotificationPriority
    public var hasAction: Bool
    public init(id: UUID, appName: String, iconSymbol: String?, bundleID: String?, title: String, subtitle: String?, body: String?,
                isRedacted: Bool, priority: NotificationPriority, hasAction: Bool) {
        self.id = id; self.appName = appName; self.iconSymbol = iconSymbol; self.bundleID = bundleID; self.title = title
        self.subtitle = subtitle; self.body = body; self.isRedacted = isRedacted; self.priority = priority; self.hasAction = hasAction
    }
}

public struct NotificationSettings: Codable, Sendable, Equatable {
    public var enabled: Bool = false
    public var defaultDuration: TimeInterval = 4
    public var maxQueue: Int = 5
    public var dedupeWindow: TimeInterval = 10
    public var privacyMode: NotificationPrivacyMode = .hidePreview
    public var focusPolicy: NotificationFocusPolicy = .silenceExceptCritical
    public var enabledSources: Set<NotificationSource> = [.atoll, .cli, .agentClaude, .agentCodex, .extensionApp]
    public var rateLimitPerMinute: Int = 30
    public var historyLimit: Int = 50
    public init() {}
}
