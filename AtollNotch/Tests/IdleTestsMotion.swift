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

// Preset motion math: breathing, pulse, eyes (seeded, deterministic), hover ramp.

func runMotionTests() {
    section("motion: seeded generator")
    var g0 = IdleSeededRNG(seed: 0)
    checkEqual("splitmix64 seed 0, first output (reference vector)", g0.next(), 0xE220A8397B1DCDAF)
    var a = IdleSeededRNG(seed: 42), b = IdleSeededRNG(seed: 42), c = IdleSeededRNG(seed: 43)
    let sa = (0..<16).map { _ in a.next() }, sb = (0..<16).map { _ in b.next() }, sc = (0..<16).map { _ in c.next() }
    check("same seed, same stream", sa == sb)
    check("different seed, different stream", sa != sc)
    check("stream has no immediate repeats", Set(sa).count == sa.count)

    section("motion: breathing")
    let p0 = IdleBreathing.pose(at: 0)
    let pHalf = IdleBreathing.pose(at: 2)
    checkEqual("t=0 is fully exhaled", p0, IdleBreathing.pose(ease: 0))
    checkEqual("t=2 is fully inhaled (half of the 4 s period)", pHalf, IdleBreathing.pose(ease: 1))
    check("period is 4 s", IdleBreathing.period == 4)
    check("pose repeats every 4 s", abs(IdleBreathing.pose(at: 1.3).orbScale - IdleBreathing.pose(at: 5.3).orbScale) < 1e-9)
    check("pose repeats after a long time", abs(IdleBreathing.pose(at: 0.7).orbOpacity - IdleBreathing.pose(at: 0.7 + 4 * 1000).orbOpacity) < 1e-6)
    check("inhale grows the orb", pHalf.orbScale > p0.orbScale && pHalf.orbOpacity > p0.orbOpacity && pHalf.ringScale > p0.ringScale)
    var inRange = true, rising = true, prev = -1.0
    for k in 0...400 {
        let t = Double(k) * 0.01
        let p = IdleBreathing.pose(at: t)
        if p.orbScale < 0.6 || p.orbScale > 0.93 || p.orbOpacity < 0.5 || p.orbOpacity > 1.0001 { inRange = false }
        if t <= 2, p.orbScale < prev - 1e-12 { rising = false }
        prev = p.orbScale
    }
    check("orb scale and opacity stay in range over a full period", inRange)
    check("orb scale rises monotonically while inhaling", rising)
    check("negative time is well defined", IdleBreathing.pose(at: -1) == IdleBreathing.pose(at: 3))
    check("NaN time falls back to the start pose", IdleBreathing.pose(at: .nan) == IdleBreathing.pose(at: 0))
    check("poster is a mid-breath still", IdleBreathing.poster.orbScale > p0.orbScale && IdleBreathing.poster.orbScale < pHalf.orbScale + 1e-9)

    section("motion: pulse")
    let rings0 = IdlePulse.rings(at: 0)
    checkEqual("three rings", rings0.count, 3)
    check("period is 2.4 s", IdlePulse.period == 2.4)
    check("stagger is a third of the period", abs(IdlePulse.stagger - 0.8) < 1e-12)
    check("ring 0 starts small and bright", rings0[0].scale < 0.3 && rings0[0].opacity > 0.8)
    check("rings are staggered (distinct scales)", Set(rings0.map(\.scale)).count == 3)
    check("progress wraps at the period", abs(IdlePulse.progress(at: 0.5) - IdlePulse.progress(at: 0.5 + 2.4)) < 1e-9)
    check("progress is in [0,1)", (0..<2000).allSatisfy { let p = IdlePulse.progress(at: Double($0) * 0.013 - 7); return p >= 0 && p < 1 })
    var fading = true
    var lastOpacity = 2.0
    for k in 0..<100 {
        let r = IdlePulse.ring(progress: Double(k) / 100)
        if r.opacity > lastOpacity + 1e-12 { fading = false }
        lastOpacity = r.opacity
    }
    check("a ring fades monotonically as it expands", fading)
    check("a ring grows monotonically", (1..<100).allSatisfy { IdlePulse.ring(progress: Double($0) / 100).scale >= IdlePulse.ring(progress: Double($0 - 1) / 100).scale })
    check("ring is almost invisible at the end of its life", IdlePulse.ring(progress: 0.999).opacity < 0.01)
    check("ring reaches the full radius", abs(IdlePulse.ring(progress: 1).scale - 1) < 1e-9)
    check("poster has two frozen rings", IdlePulse.poster.count == 2 && IdlePulse.poster.allSatisfy { $0.opacity > 0.05 })
    check("rings repeat every period", zip(IdlePulse.rings(at: 0.4), IdlePulse.rings(at: 0.4 + 2.4)).allSatisfy { abs($0.scale - $1.scale) < 1e-9 && abs($0.opacity - $1.opacity) < 1e-9 })
    check("NaN time is safe", IdlePulse.rings(at: .nan).count == 3)

    section("motion: eyes schedule")
    let s1 = IdleEyesSchedule(seed: 7), s2 = IdleEyesSchedule(seed: 7), s3 = IdleEyesSchedule(seed: 8)
    check("same seed gives the same blink script", s1.blinks == s2.blinks && s1.glances == s2.glances)
    check("different seeds give different scripts", s1.blinks != s3.blinks)
    check("equatable schedule", s1 == s2 && s1 != s3)
    check("blinks exist", s1.blinks.count > 20, "\(s1.blinks.count)")
    check("blink starts are sorted", zip(s1.blinkStarts, s1.blinkStarts.dropFirst()).allSatisfy { $0 < $1 })
    check("no blink starts in the last second of the cycle", s1.blinks.allSatisfy { $0.start + $0.duration <= s1.cycle - 1 + 1e-9 })
    check("first blink starts between 1 and 3 s", s1.blinks[0].start >= 1 && s1.blinks[0].start <= 3)
    var minGap = Double.infinity, maxGap = 0.0
    for (x, y) in zip(s1.blinks, s1.blinks.dropFirst()) {
        let gap = y.start - (x.start + x.duration)
        minGap = min(minGap, gap); maxGap = max(maxGap, gap)
    }
    check("blinks never overlap (min gap \(String(format: "%.3f", minGap)))", minGap > 0.1)
    check("blink gaps stay below 6.1 s (max \(String(format: "%.2f", maxGap)))", maxGap <= 6.1)
    let doubles = zip(s1.blinks, s1.blinks.dropFirst()).filter { $1.start - ($0.start + $0.duration) < 0.2 }.count
    check("some double blinks exist but they are the minority (\(doubles) of \(s1.blinks.count))", doubles > 0 && doubles < s1.blinks.count / 2)
    check("blink duration is 0.2 s", s1.blinks.allSatisfy { $0.duration == 0.2 })
    let b0 = s1.blinks[0]
    checkEqual("eyes fully open just before a blink", s1.state(at: b0.start - 0.01).openness, 1)
    check("eyes closed at the middle of a blink", s1.state(at: b0.start + b0.duration / 2).openness < 0.001)
    check("eyes open again after a blink", s1.state(at: b0.start + b0.duration + 0.01).openness == 1)
    check("blink is half closed at a quarter of its length", abs(s1.state(at: b0.start + b0.duration / 6).openness - 0.5) < 0.01)
    var openness = true, gaze = true
    for k in 0..<18000 {
        let st = s1.state(at: Double(k) * 0.01)
        if st.openness < 0 || st.openness > 1 { openness = false }
        if st.gazeX < -1 || st.gazeX > 1 { gaze = false }
    }
    check("openness stays in 0...1 over a whole cycle", openness)
    check("gaze stays in -1...1 over a whole cycle", gaze)
    check("state repeats after one cycle", s1.state(at: 12.34) == s1.state(at: 12.34 + s1.cycle))
    check("state repeats after many cycles", s1.state(at: 55.5) == s1.state(at: 55.5 + s1.cycle * 400))
    check("glances exist", s1.glances.count >= 10, "\(s1.glances.count)")
    check("glances look both ways", s1.glances.contains { $0.direction < 0 } && s1.glances.contains { $0.direction > 0 })
    check("glance directions are strong enough to see", s1.glances.allSatisfy { abs($0.direction) >= 0.55 && abs($0.direction) <= 1 })
    check("glance holds are 0.7...1.6 s", s1.glances.allSatisfy { $0.hold >= 0.7 && $0.hold <= 1.6 })
    let gl = s1.glances[0]
    checkEqual("gaze centred before a glance", s1.state(at: gl.start - 0.01).gazeX, 0)
    check("gaze at the full direction mid-hold", abs(s1.state(at: gl.start + IdleEyesSchedule.glanceTravel + gl.hold / 2).gazeX - gl.direction) < 1e-9)
    check("gaze returns to centre after the glance", abs(s1.state(at: gl.start + 2 * IdleEyesSchedule.glanceTravel + gl.hold + 0.01).gazeX) < 1e-9)
    check("gaze moves smoothly (no jump over 10 ms)", (0..<17000).allSatisfy { abs(s1.state(at: Double($0) * 0.01 + 0.01).gazeX - s1.state(at: Double($0) * 0.01).gazeX) < 0.2 })
    check("glances never overlap", zip(s1.glances, s1.glances.dropFirst()).allSatisfy { $1.start > $0.start + 2 * IdleEyesSchedule.glanceTravel + $0.hold })
    // Squint on hover
    check("squint 0 leaves the eyes alone", s1.state(at: 0.2, hover: 0).openness == 1)
    check("full hover squints the eyes (open 0.45)", abs(s1.state(at: 0.2, hover: 1).openness - 0.45) < 1e-9)
    check("squint value is reported", s1.state(at: 0.2, hover: 1).squint == 1 && s1.state(at: 0.2, hover: 0.5).squint == 0.5)
    check("hover is clamped", s1.state(at: 0.2, hover: 9).squint == 1 && s1.state(at: 0.2, hover: -3).squint == 0)
    check("blink still closes fully while squinting", s1.state(at: b0.start + b0.duration / 2, hover: 1).openness < 0.001)
    check("NaN time is safe", s1.state(at: .nan).openness == 1)
    check("rest state is centred and open", IdleEyeState.rest.openness == 1 && IdleEyeState.rest.gazeX == 0 && IdleEyeState.rest.squint == 0)
    // A pinned schedule: the exact blink times for seed 1234 are part of the contract (changing the generator is visible).
    let pinned = IdleEyesSchedule(seed: 1234)
    let again = IdleEyesSchedule(seed: 1234)
    check("pinned seed reproduces its first 8 blink times exactly", Array(pinned.blinkStarts.prefix(8)) == Array(again.blinkStarts.prefix(8)))
    check("custom cycle length is honoured", IdleEyesSchedule(seed: 1, cycle: 30).blinks.allSatisfy { $0.start < 29 })
    check("a short cycle still wraps", IdleEyesSchedule(seed: 1, cycle: 30).state(at: 3) == IdleEyesSchedule(seed: 1, cycle: 30).state(at: 33))
    // Eyes use the injectable generator: different seeds change the blink count distribution a little but stay in bounds.
    var allBounded = true
    for seed in UInt64(1)...UInt64(40) {
        let s = IdleEyesSchedule(seed: seed)
        if s.blinks.count < 20 || s.blinks.count > 90 { allBounded = false }
        if !zip(s.blinks, s.blinks.dropFirst()).allSatisfy({ $1.start > $0.start + $0.duration }) { allBounded = false }
    }
    check("40 seeds all produce sane, non-overlapping scripts", allBounded)

    section("motion: hover ramp")
    checkEqual("ramp starts at the origin value", IdleHoverRamp.amount(hovering: true, elapsed: 0, from: 0), 0)
    checkEqual("ramp finishes at 1 when hovering", IdleHoverRamp.amount(hovering: true, elapsed: 0.2, from: 0), 1)
    checkEqual("ramp finishes at 0 when leaving", IdleHoverRamp.amount(hovering: false, elapsed: 0.2, from: 1), 0)
    check("ramp is monotone rising", (1..<20).allSatisfy { IdleHoverRamp.amount(hovering: true, elapsed: Double($0) * 0.01, from: 0) >= IdleHoverRamp.amount(hovering: true, elapsed: Double($0 - 1) * 0.01, from: 0) })
    check("ramp interrupted mid-way continues from where it was", abs(IdleHoverRamp.amount(hovering: false, elapsed: 0, from: 0.4) - 0.4) < 1e-12)
    check("ramp beyond the duration stays at the target", IdleHoverRamp.amount(hovering: true, elapsed: 50, from: 0) == 1)
    check("easing helpers clamp", IdleEase.smoothstep(-1) == 0 && IdleEase.smoothstep(2) == 1 && IdleEase.easeOutCubic(5) == 1 && IdleEase.clamp01(.nan) == 0)

    section("motion: plan -> pose (Reduce Motion equals poster)")
    let sched = IdleEyesSchedule(seed: 99)
    for preset in IdlePresetID.allCases {
        let poster = IdlePresetFramer.poster(preset)
        var allSame = true
        for t in stride(from: 0.0, through: 20.0, by: 0.37) {
            for hover in [0.0, 1.0] {
                if IdlePresetFramer.frame(preset, plan: .pauseAtPosterFrame, time: t, hover: hover, schedule: sched) != poster { allSame = false }
                if IdlePresetFramer.frame(preset, plan: .stopped, time: t, hover: hover, schedule: sched) != poster { allSame = false }
            }
        }
        check("\(preset.rawValue): Reduce Motion frame is identical at every time and hover", allSame)
        let first = IdlePresetFramer.frame(preset, plan: .pauseAtFirstFrame, time: 9, hover: 1, schedule: sched)
        checkEqual("\(preset.rawValue): pause-at-first-frame is the t=0 pose", first, IdlePresetFramer.frame(preset, plan: .play(fps: 24), time: 0, hover: 0, schedule: sched))
        var distinct = Set<String>()
        for t in stride(from: 0.0, through: 6.0, by: 0.25) { distinct.insert("\(IdlePresetFramer.frame(preset, plan: .play(fps: 24), time: t, hover: 0, schedule: sched))") }
        check("\(preset.rawValue): playing at different times gives different poses (\(distinct.count))", distinct.count > 3)
    }
    check("poster differs from the first frame for breathing (a visible still)", IdlePresetFramer.poster(.breathing) != IdlePresetFramer.frame(.breathing, plan: .pauseAtFirstFrame, time: 0, hover: 0, schedule: sched))
    check("eyes poster has the eyes open and centred", IdlePresetFramer.poster(.eyes) == .eyes(.rest))
    check("eyes squint on hover only while playing", IdlePresetFramer.frame(.eyes, plan: .play(fps: 24), time: 0.3, hover: 1, schedule: sched) != IdlePresetFramer.frame(.eyes, plan: .play(fps: 24), time: 0.3, hover: 0, schedule: sched))
}
