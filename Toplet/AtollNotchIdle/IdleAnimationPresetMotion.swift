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

// Closed-form motion of the three native idle presets. Every function is a pure function of time `t` (seconds since
// the animation started), so the SwiftUI layer only has to ask "what is the pose at t" and the tests can pin t.
// No timers, no randomness at draw time: the only randomness is the eyes' blink/glance script, generated once from a
// seeded generator (injectable) and wrapped modulo its cycle length.

// MARK: - Seeded generator

/// SplitMix64: tiny, fast, fully deterministic for a given seed.
struct IdleSeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum IdleEase {
    static func clamp01(_ x: Double) -> Double { min(1, max(0, x.isFinite ? x : 0)) }
    static func smoothstep(_ x: Double) -> Double { let t = clamp01(x); return t * t * (3 - 2 * t) }
    static func easeOutCubic(_ x: Double) -> Double { let t = clamp01(x); return 1 - pow(1 - t, 3) }
    /// 0 -> 1 -> 0 cosine wave, phase in cycles.
    static func cosineWave(_ phase: Double) -> Double { 0.5 - 0.5 * cos(2 * Double.pi * phase) }
}

// MARK: - Breathing

struct IdleBreathingPose: Equatable {
    var orbScale: Double
    var orbOpacity: Double
    var ringScale: Double
    var ringOpacity: Double
}

enum IdleBreathing {
    static let period = 4.0

    static func pose(at t: Double) -> IdleBreathingPose {
        let phase = period > 0 && t.isFinite ? (t.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period : 0
        return pose(ease: IdleEase.cosineWave(phase))
    }

    /// ease 0 = fully exhaled (small, dim), 1 = fully inhaled (large, bright).
    static func pose(ease e: Double) -> IdleBreathingPose {
        IdleBreathingPose(orbScale: 0.62 + 0.30 * e, orbOpacity: 0.55 + 0.45 * e,
                          ringScale: 0.78 + 0.22 * e, ringOpacity: 0.18 + 0.32 * e)
    }

    /// The still used for Reduce Motion: mid breath.
    static let poster = pose(ease: 0.6)
}

// MARK: - Pulse (expanding ripples)

struct IdlePulseRing: Equatable {
    var scale: Double      // 0...1 of the available radius
    var opacity: Double
    var lineWidth: Double  // fraction of the radius
}

enum IdlePulse {
    static let period = 2.4
    static let ringCount = 3
    static var stagger: Double { period / Double(ringCount) }

    static func rings(at t: Double) -> [IdlePulseRing] {
        (0..<ringCount).map { k in ring(progress: progress(at: t - Double(k) * stagger)) }
    }

    static func progress(at t: Double) -> Double {
        guard t.isFinite else { return 0 }
        let m = (t.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period)
        return m / period
    }

    static func ring(progress p: Double) -> IdlePulseRing {
        let grow = IdleEase.easeOutCubic(p)
        return IdlePulseRing(scale: 0.22 + 0.78 * grow, opacity: pow(1 - IdleEase.clamp01(p), 1.6) * 0.85, lineWidth: 0.14 - 0.08 * p)
    }

    /// A single frozen ripple for Reduce Motion.
    static let poster: [IdlePulseRing] = [ring(progress: 0.30), ring(progress: 0.72)]
}

// MARK: - Eyes

struct IdleEyeState: Equatable {
    /// 1 = open, 0 = closed (blink).
    var openness: Double
    /// -1 (left) ... 1 (right).
    var gazeX: Double
    /// 0...1, hover squint.
    var squint: Double

    static let rest = IdleEyeState(openness: 1, gazeX: 0, squint: 0)
}

struct IdleEyesSchedule: Equatable {
    struct Blink: Equatable { var start: Double; var duration: Double }
    struct Glance: Equatable { var start: Double; var hold: Double; var direction: Double }

    static let blinkDuration = 0.2
    static let glanceTravel = 0.18
    static let defaultCycle = 180.0

    let seed: UInt64
    let cycle: Double
    let blinks: [Blink]
    let glances: [Glance]

    init(seed: UInt64, cycle: Double = IdleEyesSchedule.defaultCycle) {
        self.seed = seed
        self.cycle = cycle
        var rng = IdleSeededRNG(seed: seed)
        func uniform(_ lo: Double, _ hi: Double, _ r: inout IdleSeededRNG) -> Double {
            lo + (hi - lo) * Double(r.next() >> 11) / Double(1 << 53)
        }
        // Blinks: every 2.4...6.0 s, 18 % are double blinks. Nothing starts in the last second so no event straddles
        // the wrap.
        var b: [Blink] = []
        var t = uniform(1.0, 3.0, &rng)
        let horizon = cycle - 1.0
        while t < horizon {
            b.append(Blink(start: t, duration: Self.blinkDuration))
            var end = t + Self.blinkDuration
            if uniform(0, 1, &rng) < 0.18, end + 0.12 + Self.blinkDuration < horizon {
                b.append(Blink(start: end + 0.12, duration: Self.blinkDuration))
                end += 0.12 + Self.blinkDuration
            }
            t = end + uniform(2.4, 6.0, &rng)
        }
        blinks = b
        // Glances: every 3...7 s look left or right for 0.7...1.6 s, then return.
        var g: [Glance] = []
        var gt = uniform(2.0, 5.0, &rng)
        while gt < horizon - 2.5 {
            let hold = uniform(0.7, 1.6, &rng)
            let mag = uniform(0.55, 1.0, &rng)
            let dir = (rng.next() & 1 == 0) ? -mag : mag
            g.append(Glance(start: gt, hold: hold, direction: dir))
            gt += Self.glanceTravel * 2 + hold + uniform(3.0, 7.0, &rng)
        }
        glances = g
    }

    /// `hover` is 0...1 (the caller ramps it); blink and glance are looked up on the wrapped clock.
    func state(at t: Double, hover: Double = 0) -> IdleEyeState {
        guard t.isFinite, cycle > 0 else { return IdleEyeState(openness: 1, gazeX: 0, squint: IdleEase.clamp01(hover)) }
        let m = (t.truncatingRemainder(dividingBy: cycle) + cycle) .truncatingRemainder(dividingBy: cycle)
        var open = 1.0
        for blink in blinks where m >= blink.start && m < blink.start + blink.duration {
            let u = (m - blink.start) / blink.duration
            open = 1 - sin(Double.pi * u)
            break
        }
        var gaze = 0.0
        for glance in glances where m >= glance.start && m < glance.start + 2 * Self.glanceTravel + glance.hold {
            let local = m - glance.start
            if local < Self.glanceTravel {
                gaze = glance.direction * IdleEase.smoothstep(local / Self.glanceTravel)
            } else if local < Self.glanceTravel + glance.hold {
                gaze = glance.direction
            } else {
                gaze = glance.direction * (1 - IdleEase.smoothstep((local - Self.glanceTravel - glance.hold) / Self.glanceTravel))
            }
            break
        }
        let squint = IdleEase.clamp01(hover)
        return IdleEyeState(openness: open * (1 - 0.55 * squint), gazeX: gaze, squint: squint)
    }

    /// Wrapped start times of every blink (for tests and for assertions about the script).
    var blinkStarts: [Double] { blinks.map(\.start) }
}

enum IdleHoverRamp {
    static let duration = 0.2
    /// Amount 0...1 `elapsed` seconds after the hover state flipped, continuing from `from`.
    static func amount(hovering: Bool, elapsed: Double, from: Double) -> Double {
        let step = IdleEase.clamp01(elapsed / duration)
        let target = hovering ? 1.0 : 0.0
        return from + (target - from) * IdleEase.smoothstep(step)
    }
}

// MARK: - Which pose to draw for a plan

enum IdlePresetFrame: Equatable {
    case breathing(IdleBreathingPose)
    case pulse([IdlePulseRing])
    case eyes(IdleEyeState)
}

enum IdlePresetFramer {
    /// The single place that decides what a preset looks like for a playback plan:
    ///  - `.play`               the closed-form pose at `time` (speed is applied by the caller)
    ///  - `.pauseAtFirstFrame`  the pose at t = 0, hover ignored
    ///  - `.pauseAtPosterFrame` (Reduce Motion) and `.stopped`: the still poster, hover ignored, never animated
    static func frame(_ preset: IdlePresetID, plan: IdlePlaybackPlan, time: Double, hover: Double, schedule: IdleEyesSchedule) -> IdlePresetFrame {
        switch plan {
        case .play:
            switch preset {
            case .breathing: return .breathing(IdleBreathing.pose(at: time))
            case .pulse: return .pulse(IdlePulse.rings(at: time))
            case .eyes: return .eyes(schedule.state(at: time, hover: hover))
            }
        case .pauseAtFirstFrame:
            switch preset {
            case .breathing: return .breathing(IdleBreathing.pose(at: 0))
            case .pulse: return .pulse(IdlePulse.rings(at: 0))
            case .eyes: return .eyes(schedule.state(at: 0, hover: 0))
            }
        case .pauseAtPosterFrame, .stopped:
            return poster(preset)
        }
    }

    static func poster(_ preset: IdlePresetID) -> IdlePresetFrame {
        switch preset {
        case .breathing: return .breathing(IdleBreathing.poster)
        case .pulse: return .pulse(IdlePulse.poster)
        case .eyes: return .eyes(.rest)
        }
    }
}
