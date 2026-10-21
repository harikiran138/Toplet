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
#if canImport(UserNotifications)
import UserNotifications
#endif

// Atoll's OWN UNUserNotificationCenter notifications (docs/NOTIFICATIONS-SOURCES.md, T10 probe).
// UNUserNotificationCenter is scoped to the calling app: this adapter sees only notifications Atoll itself posts. It can
// route Atoll's own banner into the notch (and suppress the system banner) but it can NOT see any other app's notifications.
// The adapter logic is framework-free (protocol-based) so tests need no UserNotifications. The real wrapper is at the bottom.

struct SystemNotificationInfo: Equatable, Sendable {
    var identifier: String
    var title: String
    var subtitle: String?
    var body: String?
    var threadIdentifier: String?
    var urlString: String?          // from userInfo["atollURL"], validated before it becomes an action
}

enum SystemPresentationChoice: Equatable, Sendable {
    case suppressBanner             // the notch shows it (or Focus/rate limit swallowed it): no system banner
    case showSystemBanner           // notch notifications are off for this source: let macOS show it
}

struct SystemAuthorizationResult: Equatable, Sendable {
    var granted: Bool
    var errorDescription: String?
    var at: Date
}

@MainActor
protocol SystemNotificationHandling: AnyObject {
    func willPresent(_ info: SystemNotificationInfo) -> SystemPresentationChoice
    func didActivate(_ info: SystemNotificationInfo)
}

@MainActor
protocol SystemNotificationCenterProviding: AnyObject {
    /// Installs (or with nil removes) the delegate that receives Atoll's own notifications.
    func install(handler: SystemNotificationHandling?)
    func requestAuthorization(_ completion: @escaping @MainActor (SystemAuthorizationResult) -> Void)
}

@MainActor
final class AtollSystemNotificationAdapter: NotificationAdapter, SystemNotificationHandling {
    let source: NotificationSource = .atoll
    private let provider: SystemNotificationCenterProviding
    private let now: () -> Date
    private var emit: ((NotchNotification) -> NotificationQueue.Decision)?

    /// The answer to "does UNUserNotificationCenter authorisation work for this ad-hoc-signed accessory app?" (audit T10).
    private(set) var lastAuthorization: SystemAuthorizationResult?
    private(set) var authorizationRequests = 0
    var onActivate: ((SystemNotificationInfo) -> Void)?
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    init(provider: SystemNotificationCenterProviding, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    func start(emit: @escaping @MainActor (NotchNotification) -> NotificationQueue.Decision) {
        self.emit = emit
        provider.install(handler: self)
    }

    func stop() {
        provider.install(handler: nil)
        emit = nil
    }

    /// Explicit: the integration decides when the system permission prompt appears. Nothing prompts at start().
    func requestAuthorization() {
        authorizationRequests += 1
        provider.requestAuthorization { [weak self] result in self?.lastAuthorization = result }
    }

    func willPresent(_ info: SystemNotificationInfo) -> SystemPresentationChoice {
        guard let emit = emit else { return .showSystemBanner }
        switch emit(notification(for: info)) {
        case .dropped(.disabled), .dropped(.sourceDisabled): return .showSystemBanner
        default: return .suppressBanner
        }
    }

    func didActivate(_ info: SystemNotificationInfo) { onActivate?(info) }

    func notification(for i: SystemNotificationInfo) -> NotchNotification {
        var action = NotificationAction.none
        if let s = i.urlString, let u = NotificationURLPolicy.validate(s, fileExists: fileExists) { action = .openURL(u) }
        return NotchNotification(source: .atoll, appName: "Toplet", iconSymbol: "bell.fill", title: i.title, subtitle: i.subtitle, body: i.body,
                                 receivedAt: now(), dedupeKey: "atoll|\(i.identifier)", threadID: i.threadIdentifier, action: action)
    }
}

// MARK: - Real UserNotifications wrapper (compiled, but only exercised in the live app: see docs for what is unverified)

#if canImport(UserNotifications)
extension SystemNotificationInfo {
    /// Extracts the display fields from a UserNotifications content object. Testable without a notification center.
    static func make(identifier: String, content: UNNotificationContent) -> SystemNotificationInfo {
        SystemNotificationInfo(identifier: identifier, title: content.title,
                               subtitle: content.subtitle.isEmpty ? nil : content.subtitle,
                               body: content.body.isEmpty ? nil : content.body,
                               threadIdentifier: content.threadIdentifier.isEmpty ? nil : content.threadIdentifier,
                               urlString: content.userInfo["atollURL"] as? String)
    }
}

@MainActor
final class UserNotificationCenterProvider: NSObject, SystemNotificationCenterProviding, UNUserNotificationCenterDelegate {
    private weak var handler: SystemNotificationHandling?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        super.init()
    }

    func install(handler: SystemNotificationHandling?) {
        self.handler = handler
        // `current()` raises outside an app bundle; it is only touched here, from the live app.
        UNUserNotificationCenter.current().delegate = handler == nil ? nil : self
    }

    func requestAuthorization(_ completion: @escaping @MainActor (SystemAuthorizationResult) -> Void) {
        let clock = now
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            let result = SystemAuthorizationResult(granted: granted, errorDescription: error?.localizedDescription, at: clock())
            Task { @MainActor in completion(result) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = SystemNotificationInfo.make(identifier: notification.request.identifier, content: notification.request.content)
        Task { @MainActor in
            let choice = self.handler?.willPresent(info) ?? .showSystemBanner
            completionHandler(choice == .suppressBanner ? [] : [.banner, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = SystemNotificationInfo.make(identifier: response.notification.request.identifier, content: response.notification.request.content)
        Task { @MainActor in
            self.handler?.didActivate(info)
            completionHandler()
        }
    }
}
#endif
