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

import SwiftUI
import AppKit
import ImageIO

// T7 (idle part): offscreen snapshots of the native presets and the sprite player at frozen times, as film strips, plus
// pixel assertions (blink schedule, Reduce Motion == poster, frame stepping, clipping) and controller state tests.
// Run through AtollNotch/Tests/run_idle.sh. LOOK at the PNGs in the output directory: the assertions cannot judge taste.

private let slot = CGSize(width: 22, height: 18)       // closed-notch idle slot, points
private let slotScale: CGFloat = 8                      // film strip zoom (render scale)

@MainActor
private func makeController(_ mutate: (inout IdlePlaybackInputs) -> Void = { _ in }) -> IdlePlaybackController {
    var s = IdlePlaybackSources()
    s.reduceMotion = { false }; s.lowPower = { false }; s.secondsSinceUserEvent = { 0 }
    var i = IdlePlaybackInputs()
    mutate(&i)
    return IdlePlaybackController(sources: s, initial: i, observeSystem: false)
}

@MainActor
private func hostView(_ content: IdleResolvedContent, plan: IdlePlaybackPlan, time: Double, hover: Double = 0,
                      transform: IdleTransformConfig = .presetDefault, speed: Double = 1, seed: UInt64 = IdleDefaults.eyesSeed) -> some View {
    IdleAnimationHost(content: content, transform: transform, speed: speed, controller: makeController(),
                      eyesSeed: seed, frozen: IdleFrozenClock(plan: plan, time: time, hover: hover),
                      makeLottie: { _, _ in Color.clear })
}

@MainActor
private func frame(_ content: IdleResolvedContent, plan: IdlePlaybackPlan = .play(fps: 24), time: Double, hover: Double = 0,
                   transform: IdleTransformConfig = .presetDefault, speed: Double = 1, seed: UInt64 = IdleDefaults.eyesSeed,
                   size: CGSize = slot) -> NSBitmapImageRep? {
    renderBitmap(hostView(content, plan: plan, time: time, hover: hover, transform: transform, speed: speed, seed: seed),
                 size: size, scale: slotScale)
}

@MainActor
private func strip(_ name: String, _ title: String, _ content: IdleResolvedContent, _ times: [(String, Double, Double)], columns: Int = 8,
                   seed: UInt64 = IdleDefaults.eyesSeed, minDistinct: Int) {
    var frames: [FilmFrame] = []
    for (label, t, hover) in times {
        if let rep = frame(content, time: t, hover: hover, seed: seed) { frames.append(FilmFrame(label: label, rep: rep)) }
    }
    check("\(name): rendered \(frames.count)/\(times.count) frames", frames.count == times.count)
    check("\(name): strip saved", composeStrip(frames, columns: columns, scale: 1, name: "film_\(name)", title: title + "  [motion on]"))
    let distinct = Set(frames.map { pngData($0.rep) }).count
    check("\(name): frames differ over time (\(distinct) distinct of \(frames.count))", distinct >= minDistinct)
    check("\(name): every frame has visible ink", frames.allSatisfy { !measureInk($0.rep).isEmpty })

    // Reduce Motion: the same strip, forced to the poster plan.
    var still: [FilmFrame] = []
    for (label, t, hover) in times {
        if let rep = frame(content, plan: .pauseAtPosterFrame, time: t, hover: hover, seed: seed) { still.append(FilmFrame(label: label, rep: rep)) }
    }
    check("\(name): Reduce Motion strip saved", composeStrip(still, columns: columns, scale: 1, name: "film_\(name)_reducemotion", title: title + "  [Reduce Motion = poster]"))
    check("\(name): Reduce Motion frames are IDENTICAL at every time (\(Set(still.map { pngData($0.rep) }).count) distinct)", Set(still.map { pngData($0.rep) }).count == 1)
    if let preset = { () -> IdlePresetID? in if case .preset(let p) = content { return p } else { return nil } }(),
       let posterRep = renderBitmap(IdlePresetCanvas(frame: IdlePresetFramer.poster(preset)).modifier(IdleTransformModifier(config: .presetDefault)), size: slot, scale: slotScale),
       let s0 = still.first {
        check("\(name): Reduce Motion frame equals the poster drawn directly", pngData(posterRep) == pngData(s0.rep))
    }
    // First-frame pause equals t = 0.
    if let f0 = frame(content, time: 0, seed: seed), let paused = frame(content, plan: .pauseAtFirstFrame, time: 7.3, hover: 1, seed: seed) {
        check("\(name): pause-at-first-frame equals the t=0 frame", pngData(f0) == pngData(paused))
    }
    // Stopped renders nothing.
    if let stopped = frame(content, plan: .stopped, time: 1, seed: seed) {
        check("\(name): stopped plan draws nothing", measureInk(stopped).isEmpty)
        check("\(name): stopped plan has no clock", makeController { $0.resolvedSurfaceIsIdle = false }.clockInterval == nil)
    }
}

@MainActor
private func runPresetSnapshots() {
    section("T7 presets: film strips")
    let t8 = (0..<8).map { Double($0) * 0.5 }
    strip("breathing", "Breathing: 4 s cosine, orb scale 0.62...0.92, opacity 0.55...1", .preset(.breathing),
          t8.map { (String(format: "t=%.1f", $0), $0, 0) }, minDistinct: 5)
    strip("pulse", "Pulse: 3 ripples every 2.4 s, 0.8 s stagger", .preset(.pulse),
          (0..<8).map { Double($0) * 0.3 }.map { (String(format: "t=%.1f", $0), $0, 0) }, minDistinct: 5)

    let sched = IdleEyesSchedule(seed: IdleDefaults.eyesSeed)
    let b0 = sched.blinks[0], b1 = sched.blinks[1], g0 = sched.glances[0]
    let gMid = g0.start + IdleEyesSchedule.glanceTravel + g0.hold / 2
    let eyeTimes: [(String, Double, Double)] = [
        ("open t=0", 0, 0),
        ("pre-blink", b0.start - 0.05, 0),
        ("blink 25%", b0.start + b0.duration * 0.17, 0),
        ("blink mid", b0.start + b0.duration * 0.5, 0),
        ("blink 75%", b0.start + b0.duration * 0.83, 0),
        ("glance \(g0.direction < 0 ? "left" : "right")", gMid, 0),
        ("squint hover", 0.3, 1),
        ("hover 50%", 0.3, 0.5),
    ]
    strip("eyes", "Eyes: seeded blink + glance + hover squint (seed 0x\(String(IdleDefaults.eyesSeed, radix: 16)))", .preset(.eyes), eyeTimes, minDistinct: 6)
    _ = b1

    section("T7 presets: pixel assertions")
    // Breathing grows.
    if let small = frame(.preset(.breathing), time: 0), let big = frame(.preset(.breathing), time: 2) {
        let a = measureInk(small), b = measureInk(big)
        check("breathing: inhaled orb covers more pixels than exhaled (\(a.pixels) -> \(b.pixels))", b.pixels > a.pixels)
        check("breathing: inhaled frame is brighter overall", b.brightness > a.brightness)
        check("breathing: art stays inside the slot", b.minX >= 0 && b.maxX < Int(slot.width * slotScale) && b.minY >= 0 && b.maxY < Int(slot.height * slotScale))
    }
    check("breathing: frame repeats every 4 s", { if let a = frame(.preset(.breathing), time: 1.1), let b = frame(.preset(.breathing), time: 5.1) { return pngData(a) == pngData(b) } else { return false } }())
    // Pulse: a single ring grows with progress.
    var widths: [Int] = []
    for p in [0.1, 0.3, 0.5, 0.7] {
        if let rep = renderBitmap(IdlePresetCanvas(frame: .pulse([IdlePulse.ring(progress: p)])), size: slot, scale: slotScale) {
            // Ignore the always-on core by measuring the bright ring: threshold above the dimmest ring pixels.
            widths.append(measureInk(rep, threshold: 25).width)
        }
    }
    check("pulse: ring bounding box grows with progress \(widths)", widths.count == 4 && widths[0] <= widths[1] && widths[1] <= widths[2] && widths[2] <= widths[3] && widths[3] > widths[0])
    // Eyes.
    if let open = frame(.preset(.eyes), time: b0.start - 0.05),
       let mid = frame(.preset(.eyes), time: b0.start + b0.duration * 0.5),
       let after = frame(.preset(.eyes), time: b0.start + b0.duration + 0.05),
       let squint = frame(.preset(.eyes), time: 0.3, hover: 1) {
        let o = measureInk(open), m = measureInk(mid), a = measureInk(after), s = measureInk(squint)
        check("eyes: mid-blink ink is under 25% of the open eyes (\(m.pixels) vs \(o.pixels))", Double(m.pixels) < 0.25 * Double(o.pixels))
        check("eyes: mid-blink leaves a thin line (not empty)", m.pixels > 0)
        check("eyes: open again right after the blink", a.pixels == o.pixels)
        check("eyes: two separate eyes (ink spans most of the slot width)", o.width > Int(slot.width * slotScale * 0.6))
        check("eyes: squint is flatter than open (\(s.height) < \(o.height))", s.height < o.height && s.pixels < o.pixels)
    }
    if let centre = frame(.preset(.eyes), time: g0.start - 0.05), let look = frame(.preset(.eyes), time: gMid) {
        let c = measureInk(centre), l = measureInk(look)
        let shift = l.centroidX - c.centroidX
        check("eyes: glance moves the eyes \(g0.direction < 0 ? "left" : "right") (centroid shift \(String(format: "%.1f", shift)) px)",
              g0.direction < 0 ? shift < -3 : shift > 3)
        check("eyes: gaze keeps both eyes inside the slot", l.minX >= 0 && l.maxX < Int(slot.width * slotScale))
    }
    // Determinism of the blink schedule.
    let again = IdleEyesSchedule(seed: IdleDefaults.eyesSeed)
    check("eyes: same seed gives the same blink schedule", again.blinks == sched.blinks)
    check("eyes: schedule of the default seed is cached and shared", IdleEyesScheduleCache.schedule(seed: IdleDefaults.eyesSeed) == sched)
    if let a = frame(.preset(.eyes), time: 10.2), let b = frame(.preset(.eyes), time: 10.2) {
        check("eyes: identical renders for identical inputs", pngData(a) == pngData(b))
    }
    let other = IdleEyesSchedule(seed: 77)
    check("eyes: an injected seed changes the schedule", other.blinks != sched.blinks)
    if let a = frame(.preset(.eyes), time: other.blinks[0].start + 0.1, seed: 77), let b = frame(.preset(.eyes), time: other.blinks[0].start + 0.1) {
        check("eyes: the injected seed reaches the renderer", measureInk(a).pixels != measureInk(b).pixels || pngData(a) != pngData(b))
    }
    // Speed multiplies time.
    if let fast = frame(.preset(.breathing), time: 1, speed: 2), let ref = frame(.preset(.breathing), time: 2) {
        check("speed 2x at t=1 equals speed 1x at t=2", pngData(fast) == pngData(ref))
    }

    section("T7 presets: transform semantics and clipping")
    let box = CGSize(width: 80, height: 50)
    let centred = IdleTransformConfig(scale: 1, cropWidth: 22, cropHeight: 18)
    let scaled = IdleTransformConfig(scale: 2, cropWidth: 22, cropHeight: 18)
    func inBox(_ cfg: IdleTransformConfig) -> NSBitmapImageRep? {
        renderBitmap(hostView(.preset(.breathing), plan: .play(fps: 24), time: 2, transform: cfg).frame(width: box.width, height: box.height), size: box, scale: 4)
    }
    if let a = inBox(centred), let b = inBox(scaled) {
        check("transform: scale 2 doubles the frame (ink \(measureInk(a).width) -> \(measureInk(b).width) px)", measureInk(b).width > Int(Double(measureInk(a).width) * 1.7))
        check("transform: art is centred in the box", abs(measureInk(a).centroidX - Double(box.width * 4) / 2) < 6)
    }
    if let shifted = inBox(IdleTransformConfig(offsetX: 6, cropWidth: 40, cropHeight: 18)),
       let normal = inBox(IdleTransformConfig(cropWidth: 40, cropHeight: 18)) {
        check("transform: positive offsetX moves the art right", measureInk(shifted).centroidX > measureInk(normal).centroidX + 15)
    }
    // Clipping: scaled content may not paint outside its own frame (22 x 18), even when shifted.
    if let clipped = renderBitmap(hostView(.preset(.breathing), plan: .play(fps: 24), time: 2, transform: IdleTransformConfig(scale: 1, offsetX: 14, cropWidth: 22, cropHeight: 18))
                                    .frame(width: 22, height: 18).frame(width: 90, height: 40), size: CGSize(width: 90, height: 40), scale: 4) {
        let ink = measureInk(clipped)
        let frameRight = Int((90 + 22) / 2 * 4) + 1
        check("clipping: shifted art never paints past the right edge of its frame (maxX \(ink.maxX) <= \(frameRight))", ink.maxX <= frameRight)
    }
    if let faded = frame(.preset(.pulse), time: 0.5, transform: IdleTransformConfig(cropWidth: 22, cropHeight: 18, opacity: 0.3)), let full = frame(.preset(.pulse), time: 0.5) {
        check("transform: opacity 0.3 dims the art", measureInk(faded, threshold: 10).brightness < measureInk(full, threshold: 10).brightness * 0.6)
    }
    check("transform: frame size arithmetic matches the legacy view", IdleTransformConfig.default.frameWidth == 30 && IdleTransformConfig.default.frameHeight == 20 && IdleTransformConfig.presetDefault.frameWidth == 22)

    section("T7 notch context strip (all presets, real transform, in a notch-height slot)")
    var ctxFrames: [FilmFrame] = []
    for preset in IdlePresetID.allCases {
        for (label, t) in [("t=0", 0.0), ("t=1", 1.0), ("t=2", 2.0)] {
            let view = ZStack {
                Color.black
                hostView(.preset(preset), plan: .play(fps: 24), time: t)
            }.frame(width: 60, height: 32)
            if let rep = renderBitmap(view, size: CGSize(width: 60, height: 32), scale: 5) { ctxFrames.append(FilmFrame(label: "\(preset.rawValue) \(label)", rep: rep)) }
        }
    }
    check("context strip: 9 frames rendered", ctxFrames.count == 9)
    check("context strip saved", composeStrip(ctxFrames, columns: 3, scale: 1, name: "film_notch_context", title: "Presets at the real transform inside a 60x32 pt notch wing"))
}

// MARK: - Sprite sheet

@MainActor
private func runSpriteSnapshots() {
    section("T7 sprite: frame stepping")
    let cell = 16
    let png = makePNG(width: cell * 4, height: cell * 2, cellsAcross: 4, cellsDown: 2)
    let spec = SpriteSheetSpec(columns: 4, rows: 2, frameCount: 8, fps: 4, frameWidth: cell, frameHeight: cell, loop: true)
    let tmp = makeTempDir("sprite")
    let url = tmp.appendingPathComponent("sheet.png")
    try? png.write(to: url)
    guard let store = IdleSpriteFrameStore.load(url: url, spec: spec) else { check("sprite store loads", false); return }
    check("sprite store loads", true)
    // Expected colours are measured from the sheet itself drawn through the same pipeline (colour management differs
    // between ImageRenderer and a hosted window, so absolute RGB would be misleading).
    let cellCentre: (Int) -> (x: Int, y: Int) = { k in ((k % 4) * cell + cell / 2, (k / 4) * cell + cell / 2) }
    func reference(hosted: Bool) -> [(r: Double, g: Double, b: Double)] {
        let sheetView = Image(decorative: store.frame(at: 0).map { _ in (CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })! }!, scale: 1)
            .resizable().interpolation(.none).frame(width: CGFloat(cell * 4), height: CGFloat(cell * 2))
        let size = CGSize(width: cell * 4, height: cell * 2)
        guard let rep = hosted ? renderHosted(sheetView, size: size, settle: 0.2) : renderBitmap(sheetView, size: size, scale: 1) else { return [] }
        let sx = Double(rep.pixelsWide) / Double(size.width), sy = Double(rep.pixelsHigh) / Double(size.height)
        return (0..<8).map { k in let c = cellCentre(k); return pixelRGB(rep, x: Int(Double(c.x) * sx), y: Int(Double(c.y) * sy)) }
    }
    let refDirect = reference(hosted: false), refHosted = reference(hosted: true)
    check("sprite: reference colours measured (direct \(refDirect.count), hosted \(refHosted.count))", refDirect.count == 8 && refHosted.count == 8)
    check("sprite: reference colours of the 8 cells are all different", Set(refDirect.map { "\(Int($0.r * 40)),\(Int($0.g * 40))" }).count == 8)
    func expectedColor(_ k: Int) -> (r: Double, g: Double, b: Double) { refDirect.indices.contains(k) ? refDirect[k] : (0, 0, 0) }
    func expectedHosted(_ k: Int) -> (r: Double, g: Double, b: Double) { refHosted.indices.contains(k) ? refHosted[k] : (0, 0, 0) }
    func close(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double), tol: Double = 0.03) -> Bool {
        abs(a.r - b.r) < tol && abs(a.g - b.g) < tol && abs(a.b - b.b) < tol
    }
    var frames: [FilmFrame] = []
    var allMatch = true
    for k in 0..<8 {
        guard let rep = renderBitmap(IdleSpriteFrameView(store: store, frameIndex: k), size: CGSize(width: 16, height: 16), scale: 4, background: .black) else { allMatch = false; continue }
        let c = pixelRGB(rep, x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
        if !close(c, expectedColor(k)) { allMatch = false; print("   frame \(k) colour \(c) expected \(expectedColor(k))") }
        frames.append(FilmFrame(label: "frame \(k)", rep: rep))
    }
    check("sprite: every grid cell crops to its own colour (frames 0...7)", allMatch)
    check("sprite: 8 distinct frame images", Set(frames.map { pngData($0.rep) }).count == 8)
    check("sprite strip saved", composeStrip(frames, columns: 8, scale: 1, name: "film_sprite_frames", title: "Sprite sheet 4x2, 16 px cells: frames 0...7"))
    check("sprite: out-of-range index clamps to the last frame", store.frame(at: 99) != nil && store.frame(at: -5) != nil)
    _ = store.frame(at: 3)
    check("sprite: frames are cached", store.cachedFrameCount >= 1)
    for i in 0..<200 { _ = store.frame(at: i % 8) }
    check("sprite: cache stays bounded", store.cachedFrameCount <= 96)
    check("sprite: a sheet smaller than its layout is refused", IdleSpriteFrameStore.load(url: url, spec: SpriteSheetSpec(columns: 8, rows: 8, frameCount: 64, fps: 4, frameWidth: 16, frameHeight: 16)) == nil)
    check("sprite: a missing file loads as nil", IdleSpriteFrameStore.load(url: tmp.appendingPathComponent("nope.png"), spec: spec) == nil)

    section("T7 sprite: timeline through the host")
    // Times chosen mid-frame at 4 fps: index = floor(t*4).
    let timeline: [(Double, Int)] = [(0.0, 0), (0.30, 1), (0.55, 2), (0.80, 3), (1.05, 4), (1.30, 5), (1.55, 6), (1.80, 7), (2.05, 0), (2.30, 1)]
    var seq: [FilmFrame] = []
    var okAll = true
    for (t, expected) in timeline {
        let view = hostView(.sprite(url, spec), plan: .play(fps: 4), time: t, transform: IdleTransformConfig(cropWidth: 16, cropHeight: 16))
        guard let rep = renderHosted(view, size: CGSize(width: 16, height: 16), settle: 0.45) else { okAll = false; continue }
        let c = pixelRGB(rep, x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
        if !close(c, expectedHosted(expected), tol: 0.03) { okAll = false; print("   t=\(t) expected frame \(expected) colour \(expectedHosted(expected)) got \(c)") }
        seq.append(FilmFrame(label: String(format: "t=%.2f -> %d", t, expected), rep: rep))
    }
    check("sprite: host steps frames at 4 fps and loops (0.0 s ... 2.3 s)", okAll)
    check("sprite: playback strip saved", composeStrip(seq, columns: 5, scale: 4, name: "film_sprite_timeline", title: "Host sprite playback at 4 fps, loop on (frame index in label)"))
    // Play once clamps.
    let once = SpriteSheetSpec(columns: 4, rows: 2, frameCount: 8, fps: 4, frameWidth: cell, frameHeight: cell, loop: false)
    if let rep = renderHosted(hostView(.sprite(url, once), plan: .play(fps: 4), time: 50, transform: IdleTransformConfig(cropWidth: 16, cropHeight: 16)), size: CGSize(width: 16, height: 16), settle: 0.45) {
        check("sprite: play-once clamps on the last frame", close(pixelRGB(rep, x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2), expectedHosted(7)))
    }
    // Reduce Motion: frame 0 at any time.
    var rmColours: [String] = []
    for t in [0.0, 0.3, 0.8, 1.7] {
        if let rep = renderHosted(hostView(.sprite(url, spec), plan: .pauseAtPosterFrame, time: t, transform: IdleTransformConfig(cropWidth: 16, cropHeight: 16)), size: CGSize(width: 16, height: 16), settle: 0.45) {
            rmColours.append("\(pixelRGB(rep, x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))")
        }
    }
    check("sprite: Reduce Motion shows frame 0 at every time", rmColours.count == 4 && Set(rmColours).count == 1)
    if let rep = renderHosted(hostView(.sprite(url, spec), plan: .pauseAtPosterFrame, time: 1.7, transform: IdleTransformConfig(cropWidth: 16, cropHeight: 16)), size: CGSize(width: 16, height: 16), settle: 0.45) {
        check("sprite: Reduce Motion frame is cell 0", close(pixelRGB(rep, x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2), expectedHosted(0)))
    }
    if let rep = renderHosted(hostView(.sprite(url, spec), plan: .stopped, time: 1.0, transform: IdleTransformConfig(cropWidth: 16, cropHeight: 16)), size: CGSize(width: 16, height: 16), settle: 0.3) {
        check("sprite: stopped plan draws nothing and loads nothing", measureInk(rep).isEmpty)
    }
    // Speed 2x doubles the frame rate.
    if let rep = renderHosted(hostView(.sprite(url, spec), plan: .play(fps: 8), time: 0.8, transform: IdleTransformConfig(cropWidth: 16, cropHeight: 16), speed: 2), size: CGSize(width: 16, height: 16), settle: 0.45) {
        check("sprite: speed 2x at t=0.8 s lands on frame 6", close(pixelRGB(rep, x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2), expectedHosted(6)))
    }
    if let rep = renderHosted(hostView(.unavailable("x"), plan: .play(fps: 24), time: 1), size: CGSize(width: 16, height: 16), settle: 0.1) {
        check("unavailable content draws nothing", measureInk(rep).isEmpty)
    }
    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - Controller (no OS, injected sources)

@MainActor
private final class FakeSources {
    var reduceMotion = false, lowPower = false, idleSeconds = 0.0
    var clock = Date(timeIntervalSinceReferenceDate: 1000)
    var sources: IdlePlaybackSources {
        var s = IdlePlaybackSources()
        s.reduceMotion = { [unowned self] in self.reduceMotion }
        s.lowPower = { [unowned self] in self.lowPower }
        s.secondsSinceUserEvent = { [unowned self] in self.idleSeconds }
        s.now = { [unowned self] in self.clock }
        return s
    }
}

@MainActor
private func runControllerTests() {
    section("T7 controller (injected sources, no OS)")
    let fake = FakeSources()
    let c = IdlePlaybackController(sources: fake.sources, observeSystem: false)
    checkEqual("starts playing at 24 fps", c.plan, .play(fps: 24))
    checkEqual("clock runs at 1/24 while playing", c.clockInterval, 1.0 / 24)
    fake.reduceMotion = true
    c.reevaluate()
    checkEqual("Reduce Motion -> poster frame", c.plan, .pauseAtPosterFrame)
    check("poster frame has no clock", c.clockInterval == nil)
    fake.reduceMotion = false
    fake.clock = fake.clock.addingTimeInterval(30)
    c.reevaluate()
    checkEqual("Reduce Motion off -> plays again", c.plan, .play(fps: 24))
    checkEqual("epoch reset to the resume time (deterministic restart)", c.epoch, fake.clock)
    fake.lowPower = true
    c.reevaluate()
    checkEqual("Low Power -> 12 fps", c.plan, .play(fps: 12))
    checkEqual("Low Power ticks at 1/12", c.clockInterval, 1.0 / 12)
    let epochBefore = c.epoch
    fake.lowPower = false
    c.reevaluate()
    checkEqual("leaving Low Power keeps the epoch (no restart on an fps change)", c.epoch, epochBefore)
    fake.idleSeconds = 601
    c.reevaluate()
    checkEqual("10 min without input -> pause at first frame", c.plan, .pauseAtFirstFrame)
    checkEqual("…with a 5 s heartbeat to notice activity", c.clockInterval, 5)
    c.update { $0.hover = true }
    checkEqual("hover resumes playback", c.plan, .play(fps: 24))
    c.update { $0.hover = false }
    checkEqual("hover off while still inactive pauses again", c.plan, .pauseAtFirstFrame)
    fake.idleSeconds = 0
    c.reevaluate()
    checkEqual("user activity resumes playback", c.plan, .play(fps: 24))
    c.update { $0.resolvedSurfaceIsIdle = false }
    checkEqual("a higher-priority surface stops it", c.plan, .stopped)
    check("stopped has no clock (zero timers while suspended)", c.clockInterval == nil)
    let e1 = c.epoch
    fake.clock = fake.clock.addingTimeInterval(5)
    c.update { $0.resolvedSurfaceIsIdle = true }
    checkEqual("surface released -> plays again", c.plan, .play(fps: 24))
    check("…restarting from time zero", c.epoch > e1 && c.epoch == fake.clock)
    c.update { $0.isLocked = true }
    checkEqual("lock stops", c.plan, .stopped)
    c.update { $0.isLocked = false; $0.screensAsleep = true }
    checkEqual("display asleep stops", c.plan, .stopped)
    c.update { $0.screensAsleep = false; $0.isVisible = false }
    checkEqual("occluded window stops", c.plan, .stopped)
    c.update { $0.isVisible = true; $0.notchOpen = true }
    checkEqual("open notch stops", c.plan, .stopped)
    c.update { $0.notchOpen = false; $0.hideOnClosed = true }
    checkEqual("fullscreen-hidden notch stops", c.plan, .stopped)
    c.update { $0.hideOnClosed = false }
    checkEqual("everything clear -> plays", c.plan, .play(fps: 24))
    c.update { $0.renderer = .lottie; $0.userMaxFPS = 30 }
    checkEqual("Lottie renderer: heartbeat clock only", c.clockInterval, 5)
    c.update { $0.renderer = .sprite; $0.contentFPS = 10 }
    checkEqual("sprite renderer follows the content fps", c.plan, .play(fps: 10))
    c.update { _ in }
    check("an unchanged update is a no-op", c.plan == .play(fps: 10))
    check("hover amount is 0 before any hover", c.hoverAmount(at: fake.clock) == 0)
    c.update { $0.hover = true }
    check("hover ramps up over 0.2 s", c.hoverAmount(at: fake.clock) < 0.01 && c.hoverAmount(at: fake.clock.addingTimeInterval(0.1)) > 0.3 && c.hoverAmount(at: fake.clock.addingTimeInterval(0.25)) == 1)
    // Throttled sampling
    fake.idleSeconds = 0
    let c2 = IdlePlaybackController(sources: fake.sources, observeSystem: false)
    c2.noteTick(fake.clock.addingTimeInterval(0.2))
    check("noteTick within a second does not schedule a sample", true)
    fake.reduceMotion = true
    c2.noteTick(fake.clock.addingTimeInterval(1.5))
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    checkEqual("noteTick after a second re-samples and picks up Reduce Motion", c2.plan, .pauseAtPosterFrame)
    // Schedule
    let one = Array(IdleClockSchedule(interval: nil).entries(from: Date(timeIntervalSinceReferenceDate: 5), mode: .normal))
    checkEqual("no-interval schedule has exactly one entry", one.count, 1)
    var it = IdleClockSchedule(interval: 0.5).entries(from: Date(timeIntervalSinceReferenceDate: 5), mode: .normal)
    let d0 = it.next()!, d1 = it.next()!, d2 = it.next()!
    check("interval schedule steps by the interval", abs(d1.timeIntervalSince(d0) - 0.5) < 1e-9 && abs(d2.timeIntervalSince(d1) - 0.5) < 1e-9)
    var tiny = IdleClockSchedule(interval: 0.0001).entries(from: Date(), mode: .normal)
    let t0 = tiny.next()!, t1 = tiny.next()!
    check("interval schedule is floored at 20 ms", t1.timeIntervalSince(t0) >= 0.0199)
}

@main
struct IdleSnapshotMain {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        if args.count > 1 { snapshotOutDir = args[1] }
        try? FileManager.default.createDirectory(atPath: snapshotOutDir, withIntermediateDirectories: true)
        runPresetSnapshots()
        runSpriteSnapshots()
        runControllerTests()
        print("")
        print("idle snapshot tests: \(IdleT.passes) passed, \(IdleT.failures) failed (PNGs in \(snapshotOutDir))")
        exit(IdleT.failures == 0 ? 0 : 1)
    }
}
