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

import AppKit
import AVFoundation
import Combine
import Defaults
import Foundation
import SwiftUI

extension ClockHourFormat: Defaults.Serializable {}
extension NotchAlarm: Defaults.Serializable {}

extension Notification.Name {
    /// Posted on the main thread when an alarm starts ringing; the app delegate opens the Clock tab.
    static let atollAlarmFired = Notification.Name("AtollAlarmFired")
}

/// Rings alarms. One timer aimed at the soonest alarm, re-aimed whenever the alarms change, the Mac
/// wakes, or the clock or time zone changes, so nothing polls in the background.
@MainActor
final class AlarmManager: ObservableObject {
    static let shared = AlarmManager()

    @Published private(set) var ringing: NotchAlarm? {
        didSet { Self.isRinging = ringing != nil }
    }
    /// Readable from non-isolated code (the view coordinator), written only on the main actor.
    nonisolated(unsafe) static var isRinging = false
    @Published private(set) var next: (alarm: NotchAlarm, date: Date)?

    /// An alarm still ringing after this long stops by itself.
    private static let ringLimit: TimeInterval = 60
    /// After sleep, an alarm missed by up to this much still rings on wake; older ones are skipped.
    private static let lateGrace: TimeInterval = 15 * 60
    private static let snoozeMinutes = 9

    private var timer: Timer?
    private var stopWork: DispatchWorkItem?
    private var player: AVAudioPlayer?
    private var snoozed: (alarm: NotchAlarm, date: Date)?
    /// When the Mac last went to sleep; alarms that came due while it slept are caught up on wake.
    private var sleptAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    var alarms: [NotchAlarm] { Defaults[.notchAlarms] }

    /// Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        Defaults.publisher(.notchAlarms, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.reschedule() } }
            .store(in: &cancellables)
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.sleptAt = Date() } }
            .store(in: &cancellables)
        center.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.catchUpAfterSleep() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSSystemClockDidChange)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.reschedule() } }
            .store(in: &cancellables)
        reschedule()
    }

    // MARK: Editing

    func save(_ alarm: NotchAlarm) {
        var list = alarms
        if let index = list.firstIndex(where: { $0.id == alarm.id }) { list[index] = alarm } else { list.append(alarm) }
        Defaults[.notchAlarms] = list.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard var alarm = alarms.first(where: { $0.id == id }) else { return }
        alarm.isEnabled = enabled
        save(alarm)
    }

    func delete(_ id: UUID) {
        Defaults[.notchAlarms].removeAll { $0.id == id }
        if snoozed?.alarm.id == id { snoozed = nil }
    }

    // MARK: Ringing

    func stop() {
        stopWork?.cancel()
        player?.stop()
        player = nil
        withAnimation { ringing = nil }
    }

    func snooze() {
        guard let alarm = ringing else { return }
        stop()
        snoozed = (alarm, Date().addingTimeInterval(TimeInterval(Self.snoozeMinutes * 60)))
        reschedule()
    }

    var snoozeLabel: String { "Snooze \(Self.snoozeMinutes) min" }

    // MARK: Scheduling

    private func reschedule(now: Date = Date()) {
        timer?.invalidate()
        timer = nil
        var candidates = alarms.compactMap { alarm in alarm.nextFire(after: now).map { (alarm: alarm, date: $0) } }
        if let snoozed, snoozed.date > now { candidates.append(snoozed) }
        next = candidates.min { $0.date < $1.date }
        guard let next else { return }
        let timer = Timer(fire: next.date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fire(next.alarm, due: next.date) }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A sleeping Mac never fires the Timer. On wake, ring the latest alarm that came due during
    /// sleep if it is still within the grace period, then aim at the next one.
    private func catchUpAfterSleep(now: Date = Date()) {
        defer { sleptAt = nil }
        guard let since = sleptAt, since < now, ringing == nil else { reschedule(now: now); return }
        let missed = alarms.compactMap { alarm in alarm.nextFire(after: since).map { (alarm: alarm, date: $0) } }
            .filter { $0.date <= now && now.timeIntervalSince($0.date) <= Self.lateGrace }
            .max { $0.date < $1.date }
        if let missed { fire(missed.alarm, due: missed.date) } else { reschedule(now: now) }
    }

    private func fire(_ alarm: NotchAlarm, due: Date) {
        let now = Date()
        if snoozed?.alarm.id == alarm.id { snoozed = nil }
        // A one-off alarm switches itself off once it has had its turn, as in the Clock app.
        if alarm.repeatDays.isEmpty, alarm.isEnabled { setEnabled(false, for: alarm.id) }
        defer { reschedule(now: now) }
        // The timer fires late after sleep; ring only if the alarm is still recent enough to matter.
        // With the Clock tab off there is no Stop button, so alarms stay silent.
        guard now.timeIntervalSince(due) <= Self.lateGrace, Defaults[.enableClockFeature] else { return }
        withAnimation { ringing = alarm }
        playSound()
        NotificationCenter.default.post(name: .atollAlarmFired, object: alarm.id)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.stop() } }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ringLimit, execute: work)
    }

    /// The timer's sound (custom file when set, else the bundled one), looping until stopped.
    private func playSound() {
        var url: URL?
        if let custom = UserDefaults.standard.string(forKey: "customTimerSoundPath"), !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            url = URL(fileURLWithPath: custom)
        }
        url = url ?? Bundle.main.url(forResource: "timer", withExtension: "mp3")
            ?? Bundle.main.url(forResource: "dynamic", withExtension: "m4a")
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else {
            NSSound.beep()
            return
        }
        player.numberOfLoops = -1
        player.play()
        self.player = player
    }
}
