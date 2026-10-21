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

// T5: playback planner truth table.

private func inputs(_ mutate: (inout IdlePlaybackInputs) -> Void = { _ in }) -> IdlePlaybackInputs {
    var i = IdlePlaybackInputs()
    mutate(&i)
    return i
}

func runPlaybackTests() {
    section("T5 planner: defaults and single-signal cases")
    let p = IdlePlaybackPlanner.self
    checkEqual("all defaults plays at the user cap (24)", p.plan(inputs()), .play(fps: 24))
    checkEqual("higher-priority surface stops", p.plan(inputs { $0.resolvedSurfaceIsIdle = false }), .stopped)
    checkEqual("notch open stops", p.plan(inputs { $0.notchOpen = true }), .stopped)
    checkEqual("hideOnClosed (fullscreen) stops", p.plan(inputs { $0.hideOnClosed = true }), .stopped)
    checkEqual("locked stops", p.plan(inputs { $0.isLocked = true }), .stopped)
    checkEqual("screens asleep stops", p.plan(inputs { $0.screensAsleep = true }), .stopped)
    checkEqual("not visible (occluded) stops", p.plan(inputs { $0.isVisible = false }), .stopped)
    checkEqual("Reduce Motion shows the poster frame", p.plan(inputs { $0.reduceMotion = true }), .pauseAtPosterFrame)
    checkEqual("Low Power caps presets at 12 fps", p.plan(inputs { $0.lowPowerMode = true }), .play(fps: 12))
    checkEqual("Low Power caps sprites at 12 fps", p.plan(inputs { $0.lowPowerMode = true; $0.renderer = .sprite }), .play(fps: 12))
    checkEqual("Low Power pauses Lottie (cannot be rate-limited)", p.plan(inputs { $0.lowPowerMode = true; $0.renderer = .lottie }), .pauseAtFirstFrame)
    checkEqual("Low Power with a lower user cap keeps the lower cap", p.plan(inputs { $0.lowPowerMode = true; $0.userMaxFPS = 8 }), .play(fps: 8))
    checkEqual("inactivity 10 min pauses at first frame", p.plan(inputs { $0.secondsSinceLastUserEvent = 600 }), .pauseAtFirstFrame)
    checkEqual("inactivity just below the limit still plays", p.plan(inputs { $0.secondsSinceLastUserEvent = 599.9 }), .play(fps: 24))
    checkEqual("inactivity disabled (0 min) never pauses", p.plan(inputs { $0.inactivityMinutes = 0; $0.secondsSinceLastUserEvent = 1e9 }), .play(fps: 24))
    checkEqual("inactivity 1 min boundary", p.plan(inputs { $0.inactivityMinutes = 1; $0.secondsSinceLastUserEvent = 60 }), .pauseAtFirstFrame)
    checkEqual("hover counts as activity", p.plan(inputs { $0.secondsSinceLastUserEvent = 9999; $0.hover = true }), .play(fps: 24))
    checkEqual("hover alone changes nothing", p.plan(inputs { $0.hover = true }), .play(fps: 24))

    section("T5 planner: fps selection")
    checkEqual("user cap 60", p.plan(inputs { $0.userMaxFPS = 60 }), .play(fps: 60))
    checkEqual("user cap above 60 clamps to 60", p.plan(inputs { $0.userMaxFPS = 240 }), .play(fps: 60))
    checkEqual("user cap 0 clamps to 1", p.plan(inputs { $0.userMaxFPS = 0 }), .play(fps: 1))
    checkEqual("negative user cap clamps to 1", p.plan(inputs { $0.userMaxFPS = -5 }), .play(fps: 1))
    checkEqual("NaN user cap falls back to 24", p.plan(inputs { $0.userMaxFPS = .nan }), .play(fps: 24))
    checkEqual("infinite user cap falls back to 24", p.plan(inputs { $0.userMaxFPS = .infinity }), .play(fps: 24))
    checkEqual("sprite fps below the cap wins", p.plan(inputs { $0.renderer = .sprite; $0.contentFPS = 10 }), .play(fps: 10))
    checkEqual("sprite fps above the cap is capped", p.plan(inputs { $0.renderer = .sprite; $0.contentFPS = 60 }), .play(fps: 24))
    checkEqual("content fps 0 is ignored", p.plan(inputs { $0.contentFPS = 0 }), .play(fps: 24))
    checkEqual("content fps NaN is ignored", p.plan(inputs { $0.contentFPS = .nan }), .play(fps: 24))
    checkEqual("sprite 8 fps in low power stays 8", p.plan(inputs { $0.renderer = .sprite; $0.contentFPS = 8; $0.lowPowerMode = true }), .play(fps: 8))
    checkEqual("clamp helper", p.clamp(100), 60)
    checkEqual("clamp helper lower", p.clamp(0.1), 1)

    section("T5 planner: precedence")
    checkEqual("stopped beats Reduce Motion", p.plan(inputs { $0.resolvedSurfaceIsIdle = false; $0.reduceMotion = true }), .stopped)
    checkEqual("locked beats Reduce Motion", p.plan(inputs { $0.isLocked = true; $0.reduceMotion = true }), .stopped)
    checkEqual("Reduce Motion beats inactivity", p.plan(inputs { $0.reduceMotion = true; $0.secondsSinceLastUserEvent = 99999 }), .pauseAtPosterFrame)
    checkEqual("Reduce Motion beats Low Power", p.plan(inputs { $0.reduceMotion = true; $0.lowPowerMode = true }), .pauseAtPosterFrame)
    checkEqual("Reduce Motion beats hover", p.plan(inputs { $0.reduceMotion = true; $0.hover = true }), .pauseAtPosterFrame)
    checkEqual("inactivity beats Low Power for presets", p.plan(inputs { $0.lowPowerMode = true; $0.secondsSinceLastUserEvent = 99999 }), .pauseAtFirstFrame)
    checkEqual("asleep beats everything", p.plan(inputs { $0.screensAsleep = true; $0.reduceMotion = true; $0.lowPowerMode = true }), .stopped)
    checkEqual("notch open beats Reduce Motion", p.plan(inputs { $0.notchOpen = true; $0.reduceMotion = true }), .stopped)
    checkEqual("never animates under Reduce Motion with Lottie", p.plan(inputs { $0.reduceMotion = true; $0.renderer = .lottie }), .pauseAtPosterFrame)
    checkEqual("never animates under Reduce Motion with sprites", p.plan(inputs { $0.reduceMotion = true; $0.renderer = .sprite; $0.contentFPS = 30 }), .pauseAtPosterFrame)

    section("T5 planner: exhaustive invariants")
    var total = 0, stoppedBad = 0, rmBad = 0, lpBad = 0, fpsBad = 0, stillBad = 0, playBad = 0
    for bits in 0..<(1 << 8) {
        for renderer in [IdleRendererKind.preset, .sprite, .lottie] {
            for secs in [0.0, 599.0, 600.0, 7200.0] {
                for fpsCase in [1.0, 24.0, 60.0] {
                    var i = IdlePlaybackInputs()
                    i.resolvedSurfaceIsIdle = bits & 1 != 0
                    i.notchOpen = bits & 2 != 0
                    i.hideOnClosed = bits & 4 != 0
                    i.isLocked = bits & 8 != 0
                    i.screensAsleep = bits & 16 != 0
                    i.lowPowerMode = bits & 32 != 0
                    i.reduceMotion = bits & 64 != 0
                    i.hover = bits & 128 != 0
                    i.renderer = renderer
                    i.secondsSinceLastUserEvent = secs
                    i.userMaxFPS = fpsCase
                    let plan = p.plan(i)
                    total += 1
                    let mustStop = !i.resolvedSurfaceIsIdle || i.notchOpen || i.hideOnClosed || i.isLocked || i.screensAsleep
                    if mustStop != (plan == .stopped) { stoppedBad += 1 }
                    if !mustStop && i.reduceMotion && plan != .pauseAtPosterFrame { rmBad += 1 }
                    if i.reduceMotion && plan.isPlaying { rmBad += 1 }
                    if let f = plan.fps {
                        if f < 1 || f > 60 || f > fpsCase + 1e-9 { fpsBad += 1 }
                        if i.lowPowerMode && f > 12 { lpBad += 1 }
                    }
                    if plan == .pauseAtPosterFrame && !i.reduceMotion { stillBad += 1 }
                    if plan.isPlaying && (i.reduceMotion || (i.lowPowerMode && renderer == .lottie)) { playBad += 1 }
                    // determinism: same inputs, same plan
                    if p.plan(i) != plan { stillBad += 1 }
                }
            }
        }
    }
    check("enumerated \(total) input combinations", total == 256 * 3 * 4 * 3)
    checkEqual("stopped exactly when a suspend condition holds", stoppedBad, 0)
    checkEqual("Reduce Motion never animates", rmBad, 0)
    checkEqual("Low Power never exceeds 12 fps", lpBad, 0)
    checkEqual("fps always within 1...60 and not above the user cap", fpsBad, 0)
    checkEqual("poster frame only under Reduce Motion, plan is deterministic", stillBad, 0)
    checkEqual("never plays under Reduce Motion, nor Lottie in Low Power", playBad, 0)

    section("T5 planner: clock and resume")
    checkEqual("play(24) ticks at 1/24", p.clockInterval(for: .play(fps: 24), inputs: inputs()), 1.0 / 24)
    check("stopped has no clock", p.clockInterval(for: .stopped, inputs: inputs()) == nil)
    check("poster has no clock", p.clockInterval(for: .pauseAtPosterFrame, inputs: inputs { $0.reduceMotion = true }) == nil)
    checkEqual("inactivity pause keeps a 5 s heartbeat", p.clockInterval(for: .pauseAtFirstFrame, inputs: inputs { $0.secondsSinceLastUserEvent = 9999 }), 5)
    check("low-power Lottie pause has no clock", p.clockInterval(for: .pauseAtFirstFrame, inputs: inputs { $0.lowPowerMode = true; $0.renderer = .lottie }) == nil)
    checkEqual("playing Lottie only needs the 5 s heartbeat", p.clockInterval(for: .play(fps: 24), inputs: inputs { $0.renderer = .lottie }), 5)
    check("playing Lottie with inactivity disabled needs no clock at all", p.clockInterval(for: .play(fps: 24), inputs: inputs { $0.renderer = .lottie; $0.inactivityMinutes = 0 }) == nil)
    checkEqual("sprites tick at their capped fps", p.clockInterval(for: .play(fps: 10), inputs: inputs { $0.renderer = .sprite }), 0.1)
    check("resume epoch resets when going still -> play", p.resumeEpochShouldReset(from: .pauseAtFirstFrame, to: .play(fps: 24)))
    check("resume epoch resets when going stopped -> play", p.resumeEpochShouldReset(from: .stopped, to: .play(fps: 24)))
    check("epoch does not reset play -> play (fps change)", !p.resumeEpochShouldReset(from: .play(fps: 24), to: .play(fps: 12)))
    check("epoch does not reset play -> still", !p.resumeEpochShouldReset(from: .play(fps: 24), to: .pauseAtFirstFrame))
    check("plan helpers", IdlePlaybackPlan.play(fps: 5).isPlaying && IdlePlaybackPlan.stopped.isStopped && IdlePlaybackPlan.pauseAtPosterFrame.isStill && IdlePlaybackPlan.pauseAtFirstFrame.isStill)
    check("fps accessor", IdlePlaybackPlan.play(fps: 5).fps == 5 && IdlePlaybackPlan.stopped.fps == nil)
    check("renderer cap support", IdleRendererKind.preset.supportsFPSCap && IdleRendererKind.sprite.supportsFPSCap && !IdleRendererKind.lottie.supportsFPSCap)

    // Resume is deterministic: a sequence of input changes produces the same plan sequence every time.
    var seq: [IdlePlaybackPlan] = []
    for run in 0..<2 {
        var i = IdlePlaybackInputs()
        var out: [IdlePlaybackPlan] = []
        out.append(p.plan(i))
        i.resolvedSurfaceIsIdle = false; out.append(p.plan(i))      // timer wins
        i.resolvedSurfaceIsIdle = true; out.append(p.plan(i))       // timer ends
        i.reduceMotion = true; out.append(p.plan(i))
        i.reduceMotion = false; out.append(p.plan(i))
        i.secondsSinceLastUserEvent = 700; out.append(p.plan(i))
        i.hover = true; out.append(p.plan(i))
        if run == 0 { seq = out } else { check("resume sequence is deterministic", seq == out) }
    }
    checkEqual("sequence tail resumes playing on hover", seq.last, .play(fps: 24))

    section("T5 sprite timing")
    checkEqual("t=0 is frame 0", IdleSpriteTiming.frameIndex(at: 0, fps: 12, frameCount: 8, loop: true), 0)
    checkEqual("t=1/12 is frame 1", IdleSpriteTiming.frameIndex(at: 1.0 / 12 + 0.001, fps: 12, frameCount: 8, loop: true), 1)
    checkEqual("loop wraps", IdleSpriteTiming.frameIndex(at: 8.0 / 12 + 0.001, fps: 12, frameCount: 8, loop: true), 0)
    checkEqual("loop wraps twice", IdleSpriteTiming.frameIndex(at: 17.0 / 12 + 0.001, fps: 12, frameCount: 8, loop: true), 1)
    checkEqual("play-once clamps to the last frame", IdleSpriteTiming.frameIndex(at: 100, fps: 12, frameCount: 8, loop: false), 7)
    checkEqual("play-once mid-way", IdleSpriteTiming.frameIndex(at: 3.0 / 12 + 0.001, fps: 12, frameCount: 8, loop: false), 3)
    checkEqual("negative time is frame 0", IdleSpriteTiming.frameIndex(at: -3, fps: 12, frameCount: 8, loop: true), 0)
    checkEqual("NaN time is frame 0", IdleSpriteTiming.frameIndex(at: .nan, fps: 12, frameCount: 8, loop: true), 0)
    checkEqual("zero fps is frame 0", IdleSpriteTiming.frameIndex(at: 5, fps: 0, frameCount: 8, loop: true), 0)
    checkEqual("zero frames is frame 0", IdleSpriteTiming.frameIndex(at: 5, fps: 12, frameCount: 0, loop: true), 0)
    checkEqual("single frame always 0", IdleSpriteTiming.frameIndex(at: 99, fps: 12, frameCount: 1, loop: true), 0)
    checkEqual("poster is frame 0", IdleSpriteTiming.posterIndex, 0)
    var monotone = true
    var last = -1
    for k in 0..<7 {
        let idx = IdleSpriteTiming.frameIndex(at: Double(k) / 10 + 0.0001, fps: 10, frameCount: 7, loop: false)
        if idx < last { monotone = false }
        last = idx
    }
    check("play-once frame index is monotone", monotone)
}
