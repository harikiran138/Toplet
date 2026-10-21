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
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import AppKit

// Glue between the pure `IdlePlaybackPlanner` and the operating system. It owns NO timer:
//  - Reduce Motion, Low Power Mode, display sleep/wake and app hide/unhide arrive as notifications,
//  - "seconds since the last user event" is sampled by `reevaluate()`, which the host's single TimelineView triggers at
//    most once per second (`noteTick`), and which the host slows to a 5 s heartbeat while paused for inactivity.
// While the plan is `.stopped` the host removes its TimelineView entirely, so nothing at all runs.

/// Removes its observers on deinit (a plain class so the removal is not main-actor isolated).
final class IdleObserverBag {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    func add(_ center: NotificationCenter, _ name: Notification.Name, queue: OperationQueue? = .main, _ block: @escaping (Notification) -> Void) {
        tokens.append((center, center.addObserver(forName: name, object: nil, queue: queue, using: block)))
    }
    deinit { for (c, t) in tokens { c.removeObserver(t) } }
}

struct IdlePlaybackSources {
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var lowPower: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var secondsSinceUserEvent: () -> Double = {
        // CGEventType(rawValue: ~0) is kCGAnyInputEventType. Needs no permission.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
    var now: () -> Date = { Date() }

    static let live = IdlePlaybackSources()
}

@MainActor
final class IdlePlaybackController: ObservableObject {
    /// The decision. Published only when it changes, so the host re-renders on transitions, not on every sample.
    @Published private(set) var plan: IdlePlaybackPlan
    /// Last inputs (not published). `clockInterval` is derived from them.
    private(set) var inputs: IdlePlaybackInputs
    /// Animation time zero. Reset whenever playback (re)starts, so resume is deterministic.
    private(set) var epoch: Date

    private let sources: IdlePlaybackSources
    private let observers = IdleObserverBag()
    private var lastSample: Date
    private var pendingReevaluation = false
    private var hoverAmountAtFlip = 0.0
    private var hoverFlippedAt: Date?

    init(sources: IdlePlaybackSources = .live, initial: IdlePlaybackInputs = IdlePlaybackInputs(), observeSystem: Bool = true) {
        self.sources = sources
        var i = initial
        i.reduceMotion = sources.reduceMotion()
        i.lowPowerMode = sources.lowPower()
        i.secondsSinceLastUserEvent = sources.secondsSinceUserEvent()
        self.inputs = i
        let now = sources.now()
        self.epoch = now
        self.lastSample = now
        self.plan = IdlePlaybackPlanner.plan(i)
        if observeSystem { startObserving() }
    }

    var clockInterval: Double? { IdlePlaybackPlanner.clockInterval(for: plan, inputs: inputs) }

    // MARK: Inputs

    /// Mutate any of the host-provided inputs (surface, notch state, lock, renderer, fps...), then re-plan.
    func update(_ mutate: (inout IdlePlaybackInputs) -> Void) {
        var i = inputs
        mutate(&i)
        guard i != inputs else { return }
        let hoverChanged = i.hover != inputs.hover
        if hoverChanged {
            hoverAmountAtFlip = hoverAmount(at: sources.now())
            hoverFlippedAt = sources.now()
        }
        inputs = i
        replan()
    }

    /// Re-read the sampled signals (Reduce Motion, Low Power, seconds since the last user event) and re-plan.
    func reevaluate() {
        pendingReevaluation = false
        var i = inputs
        i.reduceMotion = sources.reduceMotion()
        i.lowPowerMode = sources.lowPower()
        i.secondsSinceLastUserEvent = sources.secondsSinceUserEvent()
        lastSample = sources.now()
        inputs = i
        replan()
    }

    /// Called from inside the host's TimelineView on every tick; re-samples at most once per second.
    func noteTick(_ date: Date) {
        guard !pendingReevaluation, date.timeIntervalSince(lastSample) >= 1 else { return }
        pendingReevaluation = true
        DispatchQueue.main.async { [weak self] in self?.reevaluate() }
    }

    /// 0...1, eased over 0.2 s from the moment hover flipped.
    func hoverAmount(at date: Date) -> Double {
        guard let flipped = hoverFlippedAt else { return inputs.hover ? 1 : 0 }
        return IdleHoverRamp.amount(hovering: inputs.hover, elapsed: date.timeIntervalSince(flipped), from: hoverAmountAtFlip)
    }

    // MARK: Planning

    private func replan() {
        let new = IdlePlaybackPlanner.plan(inputs)
        if new != plan {
            if IdlePlaybackPlanner.resumeEpochShouldReset(from: plan, to: new) { epoch = sources.now() }
            plan = new
        }
    }

    private func startObserving() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.add(ws, NSWorkspace.screensDidSleepNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.update { $0.screensAsleep = true } }
        }
        observers.add(ws, NSWorkspace.screensDidWakeNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.update { $0.screensAsleep = false }; self?.reevaluate() }
        }
        observers.add(ws, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
        observers.add(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
        observers.add(NotificationCenter.default, NSApplication.didHideNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.update { $0.isVisible = false } }
        }
        observers.add(NotificationCenter.default, NSApplication.didUnhideNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.update { $0.isVisible = true } }
        }
    }
}

// MARK: - Window visibility (occlusion)

/// Reports whether the hosting window is visible (not occluded by a full-screen app, another Space, or asleep).
struct IdleVisibilityProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.onChange = onChange }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private let observers = IdleObserverBag()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            observers.add(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification) { [weak self, weak window] note in
                guard let window, (note.object as? NSWindow) === window else { return }
                self?.onChange?(window.occlusionState.contains(.visible))
            }
            onChange?(window.occlusionState.contains(.visible))
        }
    }
}
