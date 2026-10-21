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

import Foundation

// The ship's brain: pure rules from what the Mac is doing to one mood, plus how that mood moves.
// No SwiftUI, timers or system calls here, so every rule is testable on its own. ShipCompanionModel
// feeds it real signals; ShipView draws the result.

enum ShipMood: String, CaseIterable, Identifiable {
    case idle, hover, greeting, music, charging, lowBattery, sailing, celebrating, attentive, alert, offline, sleeping
    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: return "Floating"
        case .hover: return "Noticing you"
        case .greeting: return "Saying hi"
        case .music: return "Listening to music"
        case .charging: return "Charging"
        case .lowBattery: return "Battery low"
        case .sailing: return "Downloading"
        case .celebrating: return "Download finished"
        case .attentive: return "Timer running"
        case .alert: return "Timer finished"
        case .offline: return "Offline"
        case .sleeping: return "Night"
        }
    }

    /// Short spoken description for VoiceOver.
    var accessibilityDescription: String {
        switch self {
        case .idle: return "The ship is floating"
        case .hover: return "The ship is looking at the pointer"
        case .greeting: return "The ship waves hello"
        case .music: return "The ship is bobbing to the music"
        case .charging: return "The ship is charging"
        case .lowBattery: return "The ship looks tired: battery is low"
        case .sailing: return "The ship is sailing: a download is in progress"
        case .celebrating: return "The ship celebrates: a download finished"
        case .attentive: return "The ship is watching the timer"
        case .alert: return "The ship rings its bell: the timer finished"
        case .offline: return "The ship is resting: you are offline"
        case .sleeping: return "The ship is asleep for the night"
        }
    }
}

/// Everything the ship reacts to. Every field comes from a real system signal or user input.
struct ShipSignals: Equatable {
    var isHovering = false
    var lastClick: Date?
    var musicPlaying = false
    var charging = false
    var batteryPercent: Int?
    var downloading = false
    var lastDownloadFinished: Date?
    var timerRunning = false
    var lastTimerFinished: Date?
    var online = true
}

enum ShipBrain {
    /// Short-lived moods: how long they win over everything below them.
    static let greetingDuration: TimeInterval = 1.2
    static let celebrationDuration: TimeInterval = 4
    static let alertDuration: TimeInterval = 6
    static let lowBatteryThreshold = 15
    /// Night runs 22:00–06:00 local time.
    static let nightHours: Set<Int> = [22, 23, 0, 1, 2, 3, 4, 5]

    /// One mood at a time, highest priority first, so two animations can never fight.
    static func mood(for s: ShipSignals, now: Date, calendar: Calendar = .autoupdatingCurrent) -> ShipMood {
        func recent(_ date: Date?, _ window: TimeInterval) -> Bool {
            guard let date else { return false }
            let age = now.timeIntervalSince(date)
            return age >= 0 && age < window
        }
        if recent(s.lastTimerFinished, alertDuration) { return .alert }
        if recent(s.lastDownloadFinished, celebrationDuration) { return .celebrating }
        if recent(s.lastClick, greetingDuration) { return .greeting }
        if s.isHovering { return .hover }
        if let p = s.batteryPercent, p <= lowBatteryThreshold, !s.charging { return .lowBattery }
        if s.downloading { return .sailing }
        if s.timerRunning { return .attentive }
        if s.musicPlaying { return .music }
        if s.charging { return .charging }
        if !s.online { return .offline }
        if nightHours.contains(calendar.component(.hour, from: now)) { return .sleeping }
        return .idle
    }

    /// When the current short-lived mood ends, so the model knows when to look again without polling.
    static func nextChange(for s: ShipSignals, now: Date) -> Date? {
        [s.lastTimerFinished.map { $0 + alertDuration },
         s.lastDownloadFinished.map { $0 + celebrationDuration },
         s.lastClick.map { $0 + greetingDuration }]
            .compactMap { $0 }.filter { $0 > now }.min()
    }
}

/// How a mood moves. Amplitudes are in points, periods in seconds.
struct ShipMotion: Equatable {
    var bob: Double          // vertical float
    var period: Double       // seconds per float cycle
    var tilt: Double         // degrees, positive = bow up
    var sway: Double         // degrees of rocking
    var waveSpeed: Double    // wave cycles per second
    /// Whether this mood is worth animating at all. Idle floats briefly, then rests (see ShipCompanionModel).
    var animates: Bool

    static let still = ShipMotion(bob: 0, period: 1, tilt: 0, sway: 0, waveSpeed: 0, animates: false)

    static func `for`(_ mood: ShipMood) -> ShipMotion {
        switch mood {
        case .idle:        return ShipMotion(bob: 0.8, period: 3.6, tilt: 0, sway: 2, waveSpeed: 0.15, animates: true)
        case .hover:       return ShipMotion(bob: 1.0, period: 2.4, tilt: 4, sway: 2, waveSpeed: 0.25, animates: true)
        case .greeting:    return ShipMotion(bob: 2.0, period: 0.6, tilt: 8, sway: 6, waveSpeed: 0.4, animates: true)
        case .music:       return ShipMotion(bob: 1.4, period: 0.5, tilt: 0, sway: 5, waveSpeed: 0.6, animates: true)
        case .charging:    return ShipMotion(bob: 0.6, period: 3.0, tilt: 0, sway: 1, waveSpeed: 0.15, animates: true)
        case .lowBattery:  return ShipMotion(bob: 0.3, period: 5.0, tilt: -3, sway: 1, waveSpeed: 0.08, animates: true)
        case .sailing:     return ShipMotion(bob: 1.0, period: 1.2, tilt: -4, sway: 2, waveSpeed: 1.0, animates: true)
        case .celebrating: return ShipMotion(bob: 2.6, period: 0.5, tilt: 6, sway: 8, waveSpeed: 0.8, animates: true)
        case .attentive:   return ShipMotion(bob: 0.5, period: 2.0, tilt: 2, sway: 1, waveSpeed: 0.2, animates: true)
        case .alert:       return ShipMotion(bob: 1.6, period: 0.4, tilt: 0, sway: 7, waveSpeed: 0.5, animates: true)
        case .offline:     return ShipMotion(bob: 0.2, period: 6.0, tilt: 0, sway: 0.5, waveSpeed: 0.05, animates: false)
        case .sleeping:    return ShipMotion(bob: 0.4, period: 6.0, tilt: 0, sway: 1, waveSpeed: 0.05, animates: false)
        }
    }

    /// Reduce Motion and Low Power Mode: no movement at all, the mood shows through the face and badge only.
    func adjusted(reduceMotion: Bool, lowPower: Bool) -> ShipMotion {
        reduceMotion || lowPower ? .still : self
    }

    /// Pose at a moment in time: (vertical offset, rotation in degrees, wave phase 0..1).
    func pose(at t: Double) -> (dy: Double, angle: Double, wave: Double) {
        guard animates, period > 0 else { return (0, tilt, 0) }
        let phase = (t / period).truncatingRemainder(dividingBy: 1) * 2 * .pi
        let wave = (t * waveSpeed).truncatingRemainder(dividingBy: 1)
        return (sin(phase) * bob, tilt + sin(phase + .pi / 2) * sway, wave)
    }
}
