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

// Producers that feed the notification queue (docs/NOTIFICATIONS-SOURCES.md). Pure mapping logic, Foundation only:
// the AtollAgents / EventKit / extension integrations are wired in the integration step and only call these adapters.
// None of them can observe other apps' notifications; there is no public API for that.

// MARK: - AI agents (Claude Code, Codex)

/// Mirror of `AgentStatus` in AtollAgents (same raw values) so this file does not depend on that module.
enum AgentActivity: String, Equatable, Sendable {
    case starting, running, waitingInput, needsPermission, idle, done, failed, stopped, unknown
}

struct AgentNotificationEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case needsPermission, needsInput, finished, failed }
    var sessionID: String
    var project: String
    var kind: Kind
    var detail: String?             // e.g. the tool summary being asked about, or the error text; hidden by the privacy mode
    init(sessionID: String, project: String, kind: Kind, detail: String? = nil) {
        self.sessionID = sessionID; self.project = project; self.kind = kind; self.detail = detail
    }
}

/// One adapter per agent (`.agentClaude` or `.agentCodex`). Every state of a session shares ONE dedupe key, so
/// "needs permission" is replaced by "finished" instead of stacking.
@MainActor
final class AgentNotificationAdapter: NotificationAdapter {
    let source: NotificationSource
    private var emit: ((NotchNotification) -> NotificationQueue.Decision)?
    private let now: () -> Date

    init(source: NotificationSource, now: @escaping () -> Date = Date.init) {
        precondition(source == .agentClaude || source == .agentCodex, "AgentNotificationAdapter handles agent sources only")
        self.source = source
        self.now = now
    }

    var agentName: String { source == .agentClaude ? "Claude Code" : "Codex" }

    func start(emit: @escaping @MainActor (NotchNotification) -> NotificationQueue.Decision) { self.emit = emit }
    func stop() { emit = nil }
    var isStarted: Bool { emit != nil }

    /// Maps a status transition the way AgentCenter reports them. Returns the queue's decision, or nil when nothing is worth saying.
    @discardableResult
    func observe(sessionID: String, project: String, from old: AgentActivity, to new: AgentActivity, detail: String? = nil) -> NotificationQueue.Decision? {
        guard old != new else { return nil }
        switch new {
        case .needsPermission:
            return handle(AgentNotificationEvent(sessionID: sessionID, project: project, kind: .needsPermission, detail: detail))
        case .waitingInput:
            return handle(AgentNotificationEvent(sessionID: sessionID, project: project, kind: .needsInput, detail: detail))
        case .done:
            // Only a session that was actually working finishes; a session discovered already idle/done is not news.
            guard [.starting, .running, .waitingInput, .needsPermission].contains(old) else { return nil }
            return handle(AgentNotificationEvent(sessionID: sessionID, project: project, kind: .finished, detail: detail))
        case .failed:
            return handle(AgentNotificationEvent(sessionID: sessionID, project: project, kind: .failed, detail: detail))
        default:
            return nil
        }
    }

    @discardableResult
    func handle(_ e: AgentNotificationEvent) -> NotificationQueue.Decision? {
        guard let emit = emit else { return nil }
        return emit(notification(for: e))
    }

    func notification(for e: AgentNotificationEvent) -> NotchNotification {
        let project = NotificationText.clean(e.project, max: 40)
        let where_ = project.isEmpty ? "a project" : project
        let title: String
        let priority: NotificationPriority
        let symbol: String
        switch e.kind {
        case .needsPermission: title = "\(agentName) needs permission in \(where_)"; priority = .high; symbol = "hand.raised.fill"
        case .needsInput: title = "\(agentName) is waiting for you in \(where_)"; priority = .normal; symbol = "ellipsis.bubble.fill"
        case .finished: title = "\(agentName) finished in \(where_)"; priority = .normal; symbol = "checkmark.circle.fill"
        case .failed: title = "\(agentName) failed in \(where_)"; priority = .high; symbol = "exclamationmark.triangle.fill"
        }
        return NotchNotification(source: source, appName: agentName, iconSymbol: symbol, title: title, body: e.detail, receivedAt: now(),
                                 priority: priority, dedupeKey: "agent|\(e.sessionID)", threadID: e.sessionID,
                                 action: .openAgentSession(e.sessionID))
    }
}

// MARK: - Extensions (AtollExtensionKit)

struct ExtensionNotificationRequest: Equatable, Sendable {
    var claimedBundleID: String             // what the app SAYS it is; never trusted on its own
    var appName: String
    var title: String
    var subtitle: String?
    var body: String?
    var symbol: String?
    var priority: NotificationPriority
    var ttl: TimeInterval?
    var dedupeKey: String?
    init(claimedBundleID: String, appName: String, title: String, subtitle: String? = nil, body: String? = nil, symbol: String? = nil,
         priority: NotificationPriority = .normal, ttl: TimeInterval? = nil, dedupeKey: String? = nil) {
        self.claimedBundleID = claimedBundleID; self.appName = appName; self.title = title; self.subtitle = subtitle; self.body = body
        self.symbol = symbol; self.priority = priority; self.ttl = ttl; self.dedupeKey = dedupeKey
    }
}

/// Contract for the extension integration. DO NOT route notification text through the extension manager's JSON file
/// (`live_activities.json`, plaintext) or its DistributedNotificationCenter broadcast: the audit (A11, B12, R5) shows both
/// leak the full payload. The transport must hand text straight to `receive` in memory.
@MainActor
protocol ExtensionNotificationAdapter: NotificationAdapter {
    /// `verifiedBundleID` must come from the transport's own peer check (for XPC, derived from the peer pid), NOT from the payload.
    /// Returns nil when the request is refused.
    func receive(_ request: ExtensionNotificationRequest, verifiedBundleID: String) -> NotificationQueue.Decision?
}

/// Minimal conforming implementation: refuses anything unauthorised or whose claimed identity differs from the verified one.
/// It never authorises anybody itself.
@MainActor
final class AuthorizedExtensionNotificationAdapter: ExtensionNotificationAdapter {
    let source: NotificationSource = .extensionApp
    private var emit: ((NotchNotification) -> NotificationQueue.Decision)?
    private let isAuthorized: (String) -> Bool
    private let now: () -> Date

    /// `isAuthorized` is `ExtensionAuthorizationManager`'s answer for an EXISTING authorisation entry (never create one here).
    init(isAuthorized: @escaping (String) -> Bool, now: @escaping () -> Date = Date.init) {
        self.isAuthorized = isAuthorized
        self.now = now
    }

    func start(emit: @escaping @MainActor (NotchNotification) -> NotificationQueue.Decision) { self.emit = emit }
    func stop() { emit = nil }

    func receive(_ r: ExtensionNotificationRequest, verifiedBundleID: String) -> NotificationQueue.Decision? {
        guard let emit = emit else { return nil }
        guard let verified = NotificationText.bundleID(verifiedBundleID), verified == r.claimedBundleID, isAuthorized(verified) else { return nil }
        let n = NotchNotification(source: .extensionApp, appName: r.appName, bundleID: verified, iconSymbol: r.symbol, title: r.title,
                                  subtitle: r.subtitle, body: r.body, receivedAt: now(), priority: r.priority, ttl: r.ttl,
                                  dedupeKey: r.dedupeKey.map { "ext|\(verified)|\($0)" }, action: .activateApp(bundleID: verified))
        return emit(n)
    }
}

// MARK: - EventKit (thin stubs: the providers wrap the existing CalendarService / reminder managers later)

struct CalendarAlert: Equatable, Sendable {
    var eventID: String
    var title: String
    var start: Date
    var location: String?
    var calendarName: String?
    init(eventID: String, title: String, start: Date, location: String? = nil, calendarName: String? = nil) {
        self.eventID = eventID; self.title = title; self.start = start; self.location = location; self.calendarName = calendarName
    }
}

struct ReminderAlert: Equatable, Sendable {
    var reminderID: String
    var title: String
    var due: Date?
    var listName: String?
    var isCritical: Bool
    init(reminderID: String, title: String, due: Date? = nil, listName: String? = nil, isCritical: Bool = false) {
        self.reminderID = reminderID; self.title = title; self.due = due; self.listName = listName; self.isCritical = isCritical
    }
}

@MainActor
protocol CalendarAlertProviding: AnyObject {
    var onAlert: ((CalendarAlert) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
protocol ReminderAlertProviding: AnyObject {
    var onAlert: ((ReminderAlert) -> Void)? { get set }
    func start()
    func stop()
}

enum NotificationRelativeTime {
    /// "Starting now", "In 5 min", "In 2 h", "Started 3 min ago". Deterministic (no locale, no calendar).
    static func phrase(from now: Date, to target: Date) -> String {
        let secs = target.timeIntervalSince(now)
        if abs(secs) < 60 { return "Starting now" }
        let mins = Int((abs(secs) / 60).rounded())
        if secs < 0 { return mins < 120 ? "Started \(mins) min ago" : "Started \(mins / 60) h ago" }
        return mins < 120 ? "In \(mins) min" : "In \(mins / 60) h"
    }
}

@MainActor
final class CalendarNotificationAdapter: NotificationAdapter {
    let source: NotificationSource = .calendar
    private let provider: CalendarAlertProviding
    private let now: () -> Date
    private var emit: ((NotchNotification) -> NotificationQueue.Decision)?
    private(set) var lastDecision: NotificationQueue.Decision?

    init(provider: CalendarAlertProviding, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    func start(emit: @escaping @MainActor (NotchNotification) -> NotificationQueue.Decision) {
        self.emit = emit
        provider.onAlert = { [weak self] a in self?.handle(a) }
        provider.start()
    }

    func stop() {
        provider.stop()
        provider.onAlert = nil
        emit = nil
    }

    func handle(_ a: CalendarAlert) {
        guard let emit = emit else { return }
        let t = now()
        let soon = abs(a.start.timeIntervalSince(t)) < 60
        let n = NotchNotification(source: .calendar, appName: a.calendarName ?? "Calendar", iconSymbol: "calendar", title: a.title,
                                  subtitle: NotificationRelativeTime.phrase(from: t, to: a.start), body: a.location, receivedAt: t,
                                  priority: soon ? .high : .normal,
                                  dedupeKey: "cal|\(a.eventID)|\(Int(a.start.timeIntervalSince1970))",
                                  action: .activateApp(bundleID: "com.apple.iCal"))
        lastDecision = emit(n)
    }
}

@MainActor
final class RemindersNotificationAdapter: NotificationAdapter {
    let source: NotificationSource = .reminders
    private let provider: ReminderAlertProviding
    private let now: () -> Date
    private var emit: ((NotchNotification) -> NotificationQueue.Decision)?
    private(set) var lastDecision: NotificationQueue.Decision?

    init(provider: ReminderAlertProviding, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    func start(emit: @escaping @MainActor (NotchNotification) -> NotificationQueue.Decision) {
        self.emit = emit
        provider.onAlert = { [weak self] a in self?.handle(a) }
        provider.start()
    }

    func stop() {
        provider.stop()
        provider.onAlert = nil
        emit = nil
    }

    func handle(_ a: ReminderAlert) {
        guard let emit = emit else { return }
        let t = now()
        let n = NotchNotification(source: .reminders, appName: a.listName ?? "Reminders", iconSymbol: "checklist", title: a.title,
                                  subtitle: a.due.map { NotificationRelativeTime.phrase(from: t, to: $0) }, receivedAt: t,
                                  priority: a.isCritical ? .critical : .normal,
                                  dedupeKey: "rem|\(a.reminderID)|\(a.due.map { String(Int($0.timeIntervalSince1970)) } ?? "none")",
                                  action: .activateApp(bundleID: "com.apple.reminders"))
        lastDecision = emit(n)
    }
}
