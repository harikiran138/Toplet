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

import Foundation

// Pure playback decision for the idle animation (docs/NOTIFICATIONS-IDLE-AUDIT.md section 7.4). No timers, no AppKit:
// the caller samples the signals (event-driven where the OS offers a notification, one cheap read per second for
// "seconds since the last user event") and asks `IdlePlaybackPlanner.plan` what to do.
//
// Outputs
//   .play(fps)           animate, at most `fps` frames per second
//   .pauseAtFirstFrame   energy pause: show frame 0 and stop the clock (inactivity, or Low Power with a renderer that
//                        cannot be rate-limited)
//   .pauseAtPosterFrame  accessibility pause: Reduce Motion. A still image, never animated
//   .stopped             release the renderer entirely (a higher priority surface, notch open, fullscreen, lock, display
//                        asleep, window not visible). Zero timers, zero views.

enum IdlePlaybackPlan: Equatable {
    case play(fps: Double)
    case pauseAtFirstFrame
    case pauseAtPosterFrame
    case stopped

    var isPlaying: Bool { if case .play = self { return true }; return false }
    var isStopped: Bool { self == .stopped }
    /// A still frame is drawn (and no per-frame clock runs).
    var isStill: Bool { self == .pauseAtFirstFrame || self == .pauseAtPosterFrame }
    var fps: Double? { if case .play(let f) = self { return f }; return nil }
}

/// What kind of renderer is in use: only native renderers can honour an fps cap exactly.
enum IdleRendererKind: Equatable {
    case preset
    case sprite
    case lottie

    var supportsFPSCap: Bool { self != .lottie }
}

struct IdlePlaybackInputs: Equatable {
    /// The arbiter's resolved closed-notch surface is the idle animation.
    var resolvedSurfaceIsIdle = true
    var notchOpen = false
    var hideOnClosed = false
    var isLocked = false
    var screensAsleep = false
    var lowPowerMode = false
    var reduceMotion = false
    var secondsSinceLastUserEvent: Double = 0
    var hover = false
    /// The window/scene is actually visible (not occluded, app not hidden).
    var isVisible = true
    /// User setting, frames per second (clamped to 1...60).
    var userMaxFPS: Double = 24
    /// 0 = never pause for inactivity.
    var inactivityMinutes: Int = 10
    var renderer: IdleRendererKind = .preset
    /// The content's own frame rate when it has one (sprite fps); nil for continuous presets.
    var contentFPS: Double?

    init() {}
}

enum IdlePlaybackPlanner {
    static let lowPowerFPSCap = 12.0
    static let minFPS = 1.0
    static let maxFPS = 60.0
    static let heartbeat = 5.0

    /// First match wins; the order is the contract (the truth table test locks it):
    ///  1. not the idle surface / open / hidden / locked / asleep / not visible  -> stopped
    ///  2. Reduce Motion                                                         -> pauseAtPosterFrame
    ///  3. inactivity timeout (hover counts as activity)                         -> pauseAtFirstFrame
    ///  4. Low Power Mode: native renderers play at <= 12 fps, Lottie pauses     -> play(<=12) / pauseAtFirstFrame
    ///  5. otherwise                                                             -> play(min(user cap, content fps))
    static func plan(_ i: IdlePlaybackInputs) -> IdlePlaybackPlan {
        if !i.resolvedSurfaceIsIdle || i.notchOpen || i.hideOnClosed || i.isLocked || i.screensAsleep || !i.isVisible {
            return .stopped
        }
        if i.reduceMotion { return .pauseAtPosterFrame }
        if isInactive(i) { return .pauseAtFirstFrame }
        var fps = clamp(i.userMaxFPS)
        if let content = i.contentFPS, content.isFinite, content > 0 { fps = min(fps, clamp(content)) }
        if i.lowPowerMode {
            guard i.renderer.supportsFPSCap else { return .pauseAtFirstFrame }
            fps = min(fps, lowPowerFPSCap)
        }
        return .play(fps: fps)
    }

    static func isInactive(_ i: IdlePlaybackInputs) -> Bool {
        guard i.inactivityMinutes > 0, !i.hover else { return false }
        return i.secondsSinceLastUserEvent >= Double(i.inactivityMinutes) * 60
    }

    static func clamp(_ fps: Double) -> Double {
        guard fps.isFinite else { return 24 }
        return min(max(fps, minFPS), maxFPS)
    }

    /// How the single clock should run for a plan: seconds between ticks, or nil for "no ticks at all".
    /// While paused for inactivity the clock slows to a 5 s heartbeat whose only job is noticing user activity (the same
    /// heartbeat is the only clock a playing Lottie needs); every other still/stopped plan is woken by notifications, so
    /// it has no clock.
    static func clockInterval(for plan: IdlePlaybackPlan, inputs: IdlePlaybackInputs) -> Double? {
        switch plan {
        case .play(let fps):
            // Lottie animates itself (Core Animation / its own display link); the clock only has to notice inactivity.
            if inputs.renderer == .lottie { return inputs.inactivityMinutes > 0 ? heartbeat : nil }
            return 1 / fps
        case .pauseAtFirstFrame: return isInactive(inputs) ? heartbeat : nil
        case .pauseAtPosterFrame, .stopped: return nil
        }
    }

    /// Hover handling for inactivity: a plan that became `pauseAtFirstFrame` by inactivity resumes the moment the
    /// seconds-since-event counter resets, with `play` restarting from time zero (deterministic resume).
    static func resumeEpochShouldReset(from old: IdlePlaybackPlan, to new: IdlePlaybackPlan) -> Bool {
        !old.isPlaying && new.isPlaying
    }
}

// MARK: - Content timing helpers (pure, shared by the sprite player and tests)

enum IdleSpriteTiming {
    /// Frame index at time `t` seconds after (re)start.
    static func frameIndex(at t: Double, fps: Double, frameCount: Int, loop: Bool) -> Int {
        guard frameCount > 0 else { return 0 }
        guard t.isFinite, t > 0, fps.isFinite, fps > 0 else { return 0 }
        let raw = Int((t * fps).rounded(.down))
        if loop { return raw % frameCount }
        return min(raw, frameCount - 1)
    }

    /// Poster still for Reduce Motion / paused: always the first frame.
    static let posterIndex = 0
}
