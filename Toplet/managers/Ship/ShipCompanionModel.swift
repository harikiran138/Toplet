/*
 * Toplet — based on Atoll (DynamicIsland)
 * Copyright (C) 2026 Toplet Contributors
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

import Combine
import Foundation
import Observation

/// Feeds the ship real signals and decides when it is worth animating. Event-driven throughout:
/// Combine for ObservableObject managers, observation tracking for DownloadManager, and one
/// timer aimed at the next moment the mood can change on its own (a greeting ending, night).
@MainActor
final class ShipCompanionModel: ObservableObject {
    static let shared = ShipCompanionModel()

    @Published private(set) var mood: ShipMood = .idle
    /// True while the ship moves: for a short burst after each mood change and while hovered,
    /// never in Low Power Mode. A single timer ends the burst, so nothing ticks while it rests.
    @Published private(set) var isAnimating = false
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled {
        didSet { if lowPower { isAnimating = false } }
    }

    /// How long a mood change keeps the ship moving. Short on purpose: the closed notch is always on screen.
    static let burst: TimeInterval = 6

    private var signals = ShipSignals()
    private var cancellables = Set<AnyCancellable>()
    private var wakeTimer: Timer?
    private var restTimer: Timer?
    private var started = false
    private var wasTimerActive = false
    private var wasDownloading = false

    /// Starts listening. Called when the ship is first shown, so a disabled companion costs nothing.
    func start() {
        guard !started else { return }
        started = true
        MusicManager.shared.$isPlaying.removeDuplicates()
            .sink { [weak self] playing in self?.update { $0.musicPlaying = playing } }
            .store(in: &cancellables)
        let battery = BatteryStatusViewModel.shared
        battery.$isCharging.combineLatest(battery.$levelBattery, battery.$isInitial)
            .sink { [weak self] charging, level, initial in
                self?.update {
                    $0.charging = charging
                    // levelBattery is 0 until the first real reading arrives; do not call that "low".
                    $0.batteryPercent = initial || level <= 0 ? nil : Int(level.rounded())
                }
            }
            .store(in: &cancellables)
        let timer = TimerManager.shared
        timer.$isTimerActive.combineLatest(timer.$isFinished)
            .sink { [weak self] active, finished in
                guard let self else { return }
                let justFinished = finished && self.wasTimerActive
                self.wasTimerActive = active && !finished
                self.update {
                    $0.timerRunning = active && !finished
                    if justFinished { $0.lastTimerFinished = Date() }
                }
            }
            .store(in: &cancellables)
        NetworkConnectivityManager.shared.$isOnline.removeDuplicates()
            .sink { [weak self] online in self?.update { $0.online = online } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
            .store(in: &cancellables)
        observeDownloads()
        reevaluate()
    }

    func setHovering(_ hovering: Bool) {
        update { $0.isHovering = hovering }
        if hovering { restTimer?.invalidate(); isAnimating = !lowPower } else { burst() }
    }

    func clicked() {
        update { $0.lastClick = Date() }
    }

    private func burst() {
        restTimer?.invalidate()
        guard !lowPower else { isAnimating = false; return }
        isAnimating = true
        let timer = Timer(timeInterval: Self.burst, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.signals.isHovering else { return }
                self.isAnimating = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        restTimer = timer
    }

    // MARK: Internals

    private func observeDownloads() {
        withObservationTracking {
            _ = DownloadManager.shared.isDownloading
            _ = DownloadManager.shared.isDownloadCompleted
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let downloading = DownloadManager.shared.isDownloading
                let finished = self.wasDownloading && !downloading && DownloadManager.shared.isDownloadCompleted
                self.wasDownloading = downloading
                self.update {
                    $0.downloading = downloading
                    if finished { $0.lastDownloadFinished = Date() }
                }
                self.observeDownloads()
            }
        }
    }

    private func update(_ change: (inout ShipSignals) -> Void) {
        var next = signals
        change(&next)
        guard next != signals else { return }
        signals = next
        reevaluate()
    }

    private func reevaluate(now: Date = Date()) {
        let next = ShipBrain.mood(for: signals, now: now)
        if next != mood {
            mood = next
            burst()
        }
        scheduleWake(now: now)
    }

    /// One timer for the next self-driven change: a short-lived mood ending, or night starting/ending.
    private func scheduleWake(now: Date) {
        wakeTimer?.invalidate()
        let calendar = Calendar.autoupdatingCurrent
        let boundaries = [22, 6].compactMap {
            calendar.nextDate(after: now, matching: DateComponents(hour: $0, minute: 0), matchingPolicy: .nextTime)
        }
        guard let next = ([ShipBrain.nextChange(for: signals, now: now)].compactMap { $0 } + boundaries).min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.05), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }
}
