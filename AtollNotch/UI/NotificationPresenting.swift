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

// The seam between the notification UI and whatever owns the queue (NotchNotificationCenter).
// The UI codes against the contract types in AtollNotch/Core/NotchNotification.swift and this protocol only.

/// One row of the in-memory history. Holds the REDACTED display (the queue redacts before it stores anything), never raw text.
public struct NotificationHistoryEntry: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var display: NotificationDisplay
    public var source: NotificationSource
    public var receivedAt: Date
    /// false = kept in history but never shown in the notch (Focus policy, rate limit, queue overflow).
    public var wasShown: Bool
    public init(id: UUID, display: NotificationDisplay, source: NotificationSource, receivedAt: Date, wasShown: Bool) {
        self.id = id; self.display = display; self.source = source; self.receivedAt = receivedAt; self.wasShown = wasShown
    }
}

/// Time left on the visible notification, as of `asOf`. The UI animates the hairline from this without any timer;
/// the queue publishes a new value whenever the countdown starts, pauses (hover) or resumes.
public struct NotificationCountdown: Sendable, Equatable {
    public var duration: TimeInterval
    public var remaining: TimeInterval
    public var asOf: Date
    public var isPaused: Bool
    public init(duration: TimeInterval, remaining: TimeInterval, asOf: Date, isPaused: Bool) {
        self.duration = duration; self.remaining = remaining; self.asOf = asOf; self.isPaused = isPaused
    }

    public func remaining(at date: Date) -> TimeInterval {
        isPaused ? remaining : max(0, remaining - date.timeIntervalSince(asOf))
    }

    public func fraction(at date: Date) -> Double {
        duration > 0 ? min(1, max(0, remaining(at: date) / duration)) : 0
    }
}

/// What `NotchNotificationCenter` conforms to. All members run on the main actor.
///
/// REQUIRED: current, queuedCount, history, settings, dismiss, performAction, setHovering.
/// OPTIONAL (default implementations below): countdown, supportsSnooze, snooze, clearHistory, sendTestNotification.
@MainActor
public protocol NotificationPresenting: ObservableObject {
    /// The notification on screen right now, already privacy-redacted. nil = nothing visible (the UI builds no tree).
    var current: NotificationDisplay? { get }
    /// Notifications waiting behind `current` (the compact form shows "+N" when > 0).
    var queuedCount: Int { get }
    /// Most recent first, redacted, in memory only.
    var history: [NotificationHistoryEntry] { get }
    /// User settings; the settings section edits this through a Binding.
    var settings: NotificationSettings { get set }

    func dismiss(_ id: UUID)
    /// Runs the notification's action (open URL, activate app, open notch tab ...) and dismisses it.
    func performAction(_ id: UUID)
    /// true while the pointer is over the notification: the queue pauses (and later resumes) the TTL.
    func setHovering(_ hovering: Bool)

    var countdown: NotificationCountdown? { get }
    var supportsSnooze: Bool { get }
    func snooze(_ id: UUID)
    func clearHistory()
    func sendTestNotification()
}

public extension NotificationPresenting {
    var countdown: NotificationCountdown? { nil }
    var supportsSnooze: Bool { false }
    func snooze(_ id: UUID) {}
    func clearHistory() {}
    func sendTestNotification() {}
}

// MARK: - Presentation model (pure)

/// Everything the notification views draw, derived from a `NotificationDisplay`. DEFENCE IN DEPTH: when `isRedacted` is true
/// the subtitle and body are dropped here even if a buggy producer passed them, so redacted text cannot reach any view,
/// accessibility label or announcement. Every string the views render comes from `visibleStrings`' fields.
public struct NotificationPresentation: Equatable, Identifiable {
    public let id: UUID
    public let appName: String
    public let bundleID: String?
    public let symbol: String
    public let title: String
    public let preview: String?
    public let showsContentHidden: Bool
    public let priority: NotificationPriority
    public let hasAction: Bool

    static let maxTitle = 160
    static let maxPreview = 320

    public init(_ d: NotificationDisplay) {
        id = d.id
        bundleID = d.bundleID
        let app = NotchUIText.oneLine(d.appName).trimmingCharacters(in: .whitespaces)
        appName = app.isEmpty ? "Notification" : String(app.prefix(60))
        let sym = (d.iconSymbol ?? "").trimmingCharacters(in: .whitespaces)
        symbol = (!sym.isEmpty && NSImage(systemSymbolName: sym, accessibilityDescription: nil) != nil) ? sym : "bell.fill"
        let t = NotchUIText.oneLine(d.title).trimmingCharacters(in: .whitespaces)
        title = t.isEmpty ? "Notification" : String(t.prefix(Self.maxTitle))
        priority = d.priority
        hasAction = d.hasAction
        if d.isRedacted {
            preview = nil
            showsContentHidden = true
        } else {
            let parts = [d.subtitle, d.body].compactMap { $0 }
                .map { NotchUIText.oneLine($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let joined = parts.joined(separator: " · ")
            preview = joined.isEmpty ? nil : String(joined.prefix(Self.maxPreview))
            showsContentHidden = false
        }
    }

    /// VoiceOver label: "App, title". Never contains the preview or anything redacted.
    public var accessibilityLabel: String { "\(appName), \(title)" }
    /// VoiceOver value: the preview, or "Content hidden" when redacted.
    public var accessibilityValue: String { showsContentHidden ? "Content hidden" : (preview ?? "") }
    /// Spoken on arrival. Critical ones are posted at high (assertive) priority.
    public var announcement: String { priority == .critical ? "Critical. \(accessibilityLabel)" : accessibilityLabel }
    public var isCritical: Bool { priority == .critical }

    /// Every user-visible string of the card, for tests.
    public var visibleStrings: [String] {
        var s = [appName, title]
        if let preview { s.append(preview) }
        if showsContentHidden { s.append("Content hidden") }
        return s
    }
}

/// Every string the card hands to VoiceOver, in one place: the view applies exactly these, and the harness asserts on them
/// (an offscreen NSHostingView exposes no accessibility tree, so the strings are checked at the source).
public enum NotificationAccessibility {
    public static let dismissLabel = "Dismiss notification"
    public static let openLabel = "Open"
    public static let openHint = "Runs the notification's action"
    public static let snoozeLabel = "Snooze notification"
    public static let dismissAction = "Dismiss"

    public static func strings(for p: NotificationPresentation, supportsSnooze: Bool) -> [String] {
        var s = [p.accessibilityLabel, p.accessibilityValue, p.announcement, dismissLabel, dismissAction]
        if p.hasAction { s += [openLabel, openHint] }
        if supportsSnooze { s.append(snoozeLabel) }
        return s
    }
}

// MARK: - Layout contracts

/// Closed-notch wings (compact form). `closedHeight` is `vm.effectiveClosedNotchHeight`; `notchWidth` is `vm.closedNotchSize.width`.
/// Wings are BALANCED (leading == trailing) so the centre gap stays over the physical notch whatever the host does with centring.
///   height          = closedHeight (outer), content height (icon side) = closedHeight - 12
///   wing width      = clamp(title + 8 + 10 + chip, 44 ... 150)           (icon side + 16 at least)
///   total width     = notchWidth + 2 * wing                              (<= notchWidth + 300)
public struct NotificationCompactLayout: Equatable {
    public var wingWidth: CGFloat
    public var centerWidth: CGFloat
    public var totalWidth: CGFloat
    public var outerHeight: CGFloat
    public var contentHeight: CGFloat
    public var iconSide: CGFloat
    public var titleWidth: CGFloat
    public var chipWidth: CGFloat

    public static let minWing: CGFloat = 44
    public static let maxWing: CGFloat = 150
    public static let innerPad: CGFloat = 8          // gap between the notch edge and the icon / title
    public static let outerPad: CGFloat = 10         // gap between the last element and the pill edge

    public static func make(title: String, queued: Int, closedHeight: CGFloat, notchWidth: CGFloat) -> NotificationCompactLayout {
        let content = max(0, closedHeight - 12)
        let chip = queued > 0 ? chipWidth(queued) : 0
        let chipPart = chip > 0 ? chip + 4 : 0
        let measured = NotchUIText.width(title, size: 12, weight: .semibold)
        let wanted = innerPad + measured + chipPart + outerPad
        let wing = min(maxWing, max(minWing, content + 16, wanted))
        let titleW = max(0, wing - innerPad - outerPad - chipPart)
        return NotificationCompactLayout(wingWidth: wing, centerWidth: notchWidth, totalWidth: notchWidth + 2 * wing,
                                         outerHeight: closedHeight, contentHeight: content, iconSide: content,
                                         titleWidth: titleW, chipWidth: chip)
    }

    static func chipWidth(_ n: Int) -> CGFloat {
        max(20, NotchUIText.width("+\(n)", size: 10, weight: .bold) + 10)
    }

    public var size: CGSize { CGSize(width: totalWidth, height: outerHeight) }
}

/// Expanded card: the notch grows downward (the battery "standard" pattern) into a rounded-bottom surface.
///   width  = clamp(notchWidth + 240, 400 ... 460)
///   height = closedHeight + 70 (title + two-line preview) + 30 (button row, only when there are buttons)
public enum NotificationExpandedLayout {
    public static let previewBlock: CGFloat = 70
    public static let buttonRow: CGFloat = 30

    public static func size(closedHeight: CGFloat, notchWidth: CGFloat, hasButtons: Bool) -> CGSize {
        CGSize(width: min(max(notchWidth + 240, 400), 460),
               height: closedHeight + previewBlock + (hasButtons ? buttonRow : 0))
    }
}

// MARK: - Privacy preview (settings only)

/// Mirrors what the queue's redactor hands the UI for each privacy mode, for the live preview in settings.
/// The REAL redaction lives in the queue (NotificationQueue); this exists so the preview works without it and is asserted
/// by the harness to agree with the contract in NotchNotification.swift.
public enum NotificationPrivacyPreview {
    public static func display(for n: NotchNotification, mode: NotificationPrivacyMode) -> NotificationDisplay {
        let effective: NotificationPrivacyMode = (n.isSensitive && mode == .off) ? .hidePreview : mode
        switch effective {
        case .off:
            return NotificationDisplay(id: n.id, appName: n.appName, iconSymbol: n.iconSymbol, bundleID: n.bundleID, title: n.title,
                                       subtitle: n.subtitle, body: n.body, isRedacted: false, priority: n.priority, hasAction: n.action != .none)
        case .hidePreview:
            return NotificationDisplay(id: n.id, appName: n.appName, iconSymbol: n.iconSymbol, bundleID: n.bundleID, title: n.title,
                                       subtitle: nil, body: nil, isRedacted: true, priority: n.priority, hasAction: n.action != .none)
        case .hideAll:
            return NotificationDisplay(id: n.id, appName: n.appName, iconSymbol: nil, bundleID: n.bundleID,
                                       title: "Notification from \(n.appName)", subtitle: nil, body: nil, isRedacted: true,
                                       priority: n.priority, hasAction: n.action != .none)
        }
    }

    public static let sample = NotchNotification(
        source: .cli, appName: "Terminal", iconSymbol: "terminal.fill", title: "Deploy finished: api-gateway",
        subtitle: "production", body: "All 214 checks passed in 3m 12s. Rollout is live in 3 regions.", priority: .normal,
        action: .openNotchTab("agents"))
}

// MARK: - Arrival announcement

/// Posts the VoiceOver announcement on arrival. Injectable so the harness can assert what would be spoken.
public struct NotificationAnnouncer {
    public var post: (_ text: String, _ assertive: Bool) -> Void
    public init(post: @escaping (_ text: String, _ assertive: Bool) -> Void) { self.post = post }

    public static let system = NotificationAnnouncer { text, assertive in
        var s = AttributedString(text)
        if assertive { s.accessibilitySpeechAnnouncementPriority = .high }
        AccessibilityNotification.Announcement(s).post()
    }
}
