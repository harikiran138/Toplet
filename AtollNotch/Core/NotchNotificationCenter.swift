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
import Combine

// @MainActor facade over one `NotificationQueue` and the `atoll-notify` ingress (docs/NOTIFICATIONS-IDLE-AUDIT.md 7.1, 7.5).
// It is a thin owner, not a presenter: the single way a notification reaches the notch is `onPresent`
// (the arbiter integration turns that into one `toggleSneakPeek`-style call). Integration notes:
//   - ContentView should NOT observe this object (audit R4: it is one more invalidation source); the integration step
//     reads `current` only through `onPresent`/`onRetract`.
//   - Settings persistence is injected (`persist`), so no Defaults wiring lives here.
//   - Notification text is never written to disk or to distributed notifications. History is in memory and holds only
//     the already-redacted display.
//   - Disabled == zero cost: `stop()` (or `settings.enabled == false`) closes the socket, stops adapters, cancels the timer.

/// Schedules ONE wake-up. Production uses `TaskNotificationScheduler`; tests inject a fake clock-driven one.
@MainActor
protocol NotificationScheduling: AnyObject {
    /// Returns a cancel closure. `fire` runs on the main actor, once, unless cancelled.
    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void
}

@MainActor
final class TaskNotificationScheduler: NotificationScheduling {
    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        let nanos = UInt64(Swift.max(0, Swift.min(delay, 3600)) * 1_000_000_000)
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            fire()
        }
        return { task.cancel() }
    }
}

/// A source of notifications other than the socket (agents, EventKit, Atoll's own UNUserNotificationCenter...).
@MainActor
protocol NotificationAdapter: AnyObject {
    var source: NotificationSource { get }
    /// Begin producing. `emit` is the facade's `present`; it returns what the queue decided.
    func start(emit: @escaping @MainActor (NotchNotification) -> NotificationQueue.Decision)
    func stop()
}

@MainActor
final class NotchNotificationCenter: ObservableObject {
    @Published private(set) var current: NotificationDisplay?
    @Published private(set) var queuedCount = 0
    @Published private(set) var history: [NotificationHistoryItem] = []
    @Published private(set) var isRunning = false
    /// Set when the socket could not be opened (e.g. insecure directory). Never contains notification text.
    @Published private(set) var ingressError: String?
    @Published var settings: NotificationSettings {
        didSet { if settings != oldValue { settingsDidChange(from: oldValue) } }
    }

    /// The one funnel into the arbiter: (redacted display, seconds to show). Called when the current item changes or its content is replaced.
    var onPresent: ((NotificationDisplay, TimeInterval) -> Void)?
    /// The current item went away and nothing replaced it (expired, dismissed, cleared). The arbiter should hide it.
    var onRetract: ((UUID) -> Void)?
    /// Performs a validated click action: open URL, activate app, open a notch tab, open an agent session.
    var actionHandler: (NotificationAction) -> Void

    private var queue: NotificationQueue
    private let clock: () -> Date
    private let scheduler: NotificationScheduling
    private let persist: (NotificationSettings) -> Void
    private let makeIngress: () -> NotificationIngressServer
    private var ingress: NotificationIngressServer?
    private var adapters: [NotificationAdapter] = []
    private var runningAdapters: [ObjectIdentifier] = []
    private var cancelTimer: (() -> Void)?
    private var scheduledDeadline: Date?
    private var presentedDisplay: NotificationDisplay?
    private var hovering = false

    init(settings: NotificationSettings = NotificationSettings(),
         persist: @escaping (NotificationSettings) -> Void = { _ in },
         clock: @escaping () -> Date = Date.init,
         scheduler: NotificationScheduling? = nil,
         isFocusActive: @escaping () -> Bool = { false },
         actionHandler: @escaping (NotificationAction) -> Void = { _ in },
         makeIngress: (() -> NotificationIngressServer)? = nil) {
        self.settings = settings
        self.persist = persist
        self.clock = clock
        self.scheduler = scheduler ?? TaskNotificationScheduler()
        self.actionHandler = actionHandler
        self.makeIngress = makeIngress ?? { NotificationIngressServer() }
        self.queue = NotificationQueue(settings: settings, isFocusActive: isFocusActive)
    }

    // MARK: Lifecycle

    func addAdapter(_ adapter: NotificationAdapter) {
        guard !adapters.contains(where: { $0 === adapter }) else { return }
        adapters.append(adapter)
        applyRuntimeState()
    }

    func removeAdapter(_ adapter: NotificationAdapter) {
        adapter.stop()
        runningAdapters.removeAll { $0 == ObjectIdentifier(adapter) }
        adapters.removeAll { $0 === adapter }
    }

    func setFocusProvider(_ provider: @escaping () -> Bool) { queue.isFocusActive = provider }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        applyRuntimeState()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        hovering = false
        applyRuntimeState()
    }

    /// Socket, adapters and timer exist only while running AND enabled.
    private func applyRuntimeState() {
        let active = isRunning && settings.enabled
        if active {
            if settings.enabledSources.contains(.cli) { startIngress() } else { stopIngress() }
            for a in adapters {
                let id = ObjectIdentifier(a)
                let want = settings.enabledSources.contains(a.source)
                let on = runningAdapters.contains(id)
                if want && !on {
                    runningAdapters.append(id)
                    a.start(emit: { [weak self] n in self?.present(n) ?? .dropped(.disabled) })
                } else if !want && on {
                    runningAdapters.removeAll { $0 == id }
                    a.stop()
                }
            }
        } else {
            stopIngress()
            for a in adapters where runningAdapters.contains(ObjectIdentifier(a)) { a.stop() }
            runningAdapters = []
            queue.dismissAll(outcome: .cleared, now: clock())
            queue.setPaused(false, now: clock())
        }
        reconcile()
    }

    private func startIngress() {
        guard ingress == nil else { return }
        let server = makeIngress()
        server.onNotification = { [weak self] n, _, reply in
            Task { @MainActor in
                guard let self = self else { reply(.error("Toplet is not accepting notifications")); return }
                reply(Self.reply(for: self.present(n), id: n.id))
            }
        }
        do {
            try server.start()
            ingress = server
            ingressError = nil
        } catch {
            ingressError = (error as? LocalizedError)?.errorDescription ?? "Could not open the notification socket."
        }
    }

    private func stopIngress() {
        ingress?.stop()
        ingress = nil
    }

    var isIngressRunning: Bool { ingress?.isRunning ?? false }

    static func reply(for d: NotificationQueue.Decision, id: UUID) -> IngressReply {
        switch d {
        case .shown(let i, _), .queued(let i, _), .deduped(let i), .silenced(let i): return .ok(id: i)
        case .rateLimited: return .error("rate limited")
        case .dropped(.disabled): return .error("notifications are turned off in Toplet")
        case .dropped(.sourceDisabled): return .error("the command line source is turned off in Toplet")
        case .dropped(.invalidContent): return .error("notification has no usable title")
        case .dropped(.queueFull): return .error("notification queue is full")
        }
    }

    // MARK: Presenting

    @discardableResult
    func present(_ n: NotchNotification) -> NotificationQueue.Decision {
        guard isRunning else { return .dropped(.disabled) }
        let d = queue.accept(n, now: clock())
        reconcile()
        return d
    }

    @discardableResult
    func dismiss(_ id: UUID) -> Bool {
        let ok = queue.dismiss(id: id, outcome: .dismissed, now: clock())
        reconcile()
        return ok
    }

    func dismissAll() {
        queue.dismissAll(outcome: .dismissed, now: clock())
        reconcile()
    }

    /// Hover pauses the TTL; leaving resumes it with the remaining time.
    func setHovering(_ h: Bool) {
        guard isRunning, h != hovering else { return }
        hovering = h
        queue.setPaused(h, now: clock())
        reconcile()
    }

    /// Click: validates the action again (a file may have vanished), performs it through the injected handler, dismisses the item.
    @discardableResult
    func performAction(_ id: UUID) -> Bool {
        guard queue.isLive(id), let stored = queue.action(for: id) else { return false }   // only a notification still on screen or queued can be clicked
        let action = queue.validated(stored)
        guard action != .none else { return false }
        actionHandler(action)
        _ = queue.dismiss(id: id, outcome: .actioned, now: clock())
        reconcile()
        return true
    }

    func clearHistory() {
        queue.clearHistory()
        reconcile()
    }

    // MARK: Internals

    private func settingsDidChange(from old: NotificationSettings) {
        queue.settings = settings
        persist(settings)
        for s in old.enabledSources.subtracting(settings.enabledSources) { queue.purge(source: s, now: clock()) }
        applyRuntimeState()
    }

    /// Single place that publishes state, informs the arbiter, and (re)arms the ONE timer.
    private func reconcile() {
        let cur = queue.current
        if queuedCount != queue.queuedCount { queuedCount = queue.queuedCount }
        if history != queue.history { history = queue.history }

        if let c = cur {
            if presentedDisplay != c.display {
                presentedDisplay = c.display
                current = c.display
                onPresent?(c.display, c.remaining)
            }
        } else if let old = presentedDisplay {
            presentedDisplay = nil
            current = nil
            onRetract?(old.id)
        }

        let want: Date? = isRunning ? queue.nextDeadline : nil
        if want != scheduledDeadline {
            cancelTimer?(); cancelTimer = nil
            scheduledDeadline = want
            if let d = want {
                let delay = Swift.max(0, d.timeIntervalSince(clock()))
                cancelTimer = scheduler.schedule(after: delay) { [weak self] in self?.timerFired() }
            }
        }
    }

    private func timerFired() {
        cancelTimer = nil
        scheduledDeadline = nil
        queue.advance(now: clock())
        reconcile()
    }

    /// Test hook: number of armed timers (0 or 1 by construction).
    var hasArmedTimer: Bool { cancelTimer != nil }
}
