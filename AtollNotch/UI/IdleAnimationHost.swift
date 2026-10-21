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

// The one renderer for every idle animation kind. It keeps ONE clock: a TimelineView whose schedule is chosen by the
// playback plan (frame rate while playing, a 5 s heartbeat while paused for inactivity, a single entry for stills).
// `.stopped` removes the TimelineView and the content altogether, so a suspended idle animation costs nothing and
// holds no renderer. Lottie playback itself is supplied by the host app through `makeLottie` (the Lottie framework is
// not linked into the snapshot harness).

/// The frame of the animation inside the notch slot, same arithmetic the old IdleAnimationView used.
struct IdleTransformModifier: ViewModifier {
    let config: IdleTransformConfig

    func body(content: Content) -> some View {
        content
            .frame(width: config.frameWidth, height: config.frameHeight)
            .offset(x: config.offsetX, y: config.offsetY)
            .rotationEffect(.degrees(config.rotation))
            .opacity(config.opacity)
            .padding(.bottom, config.paddingBottom)
            .clipped()
    }
}

/// A TimelineSchedule with a fixed interval, or a single entry when `interval` is nil. No work happens between entries.
struct IdleClockSchedule: TimelineSchedule {
    let interval: Double?

    struct Entries: Sequence, IteratorProtocol {
        let start: Date
        let step: Double?
        var index = 0
        mutating func next() -> Date? {
            defer { index += 1 }
            guard let step else { return index == 0 ? start : nil }
            return start.addingTimeInterval(Double(index) * step)
        }
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(start: startDate, step: interval.map { max(0.02, $0) })
    }
}

/// Test seam: render exactly this plan at exactly this time, with no TimelineView.
struct IdleFrozenClock: Equatable {
    var plan: IdlePlaybackPlan
    var time: Double
    var hover: Double = 0
}

struct IdleAnimationHost<LottieContent: View>: View {
    let content: IdleResolvedContent
    let transform: IdleTransformConfig
    let speed: Double
    @ObservedObject var controller: IdlePlaybackController
    var eyesSeed: UInt64 = IdleDefaults.eyesSeed
    var style = IdlePresetStyle.standard
    var frozen: IdleFrozenClock?
    let makeLottie: (URL, IdlePlaybackPlan) -> LottieContent

    var body: some View {
        let plan = frozen?.plan ?? controller.plan
        Group {
            switch content {
            case .unavailable:
                Color.clear
            case .lottie(let url):
                if plan.isStopped { Color.clear } else { lottieBody(url, plan) }
            case .preset(let preset):
                if plan.isStopped { Color.clear } else { clocked(plan) { t, hover in presetFrame(preset, plan, t, hover) } }
            case .sprite(let url, let spec):
                if plan.isStopped { Color.clear } else { clocked(plan) { t, _ in spriteFrame(url, spec, plan, t) } }
            }
        }
        .modifier(IdleTransformModifier(config: transform))
        .onHover { hovering in controller.update { $0.hover = hovering } }
        .background {
            // An NSViewRepresentable cannot be drawn by ImageRenderer, so the frozen test clock has no probe.
            if frozen == nil { IdleVisibilityProbe { visible in controller.update { $0.isVisible = visible } } }
        }
    }

    // MARK: pieces

    /// `build(time, hover)` is evaluated inside the one TimelineView (or once, for a frozen clock).
    @ViewBuilder
    private func clocked<V: View>(_ plan: IdlePlaybackPlan, _ build: @escaping (Double, Double) -> V) -> some View {
        if let frozen {
            build(frozen.time * speed, frozen.hover)
        } else {
            TimelineView(IdleClockSchedule(interval: controller.clockInterval)) { ctx in
                let _ = controller.noteTick(ctx.date)
                build(max(0, ctx.date.timeIntervalSince(controller.epoch)) * speed, controller.hoverAmount(at: ctx.date))
            }
        }
    }

    private func presetFrame(_ preset: IdlePresetID, _ plan: IdlePlaybackPlan, _ t: Double, _ hover: Double) -> some View {
        IdlePresetCanvas(frame: IdlePresetFramer.frame(preset, plan: plan, time: t, hover: hover, schedule: IdleEyesScheduleCache.schedule(seed: eyesSeed)),
                         style: style)
    }

    @ViewBuilder
    private func spriteFrame(_ url: URL, _ spec: SpriteSheetSpec, _ plan: IdlePlaybackPlan, _ t: Double) -> some View {
        let index = plan.isPlaying
            ? IdleSpriteTiming.frameIndex(at: t, fps: spec.fps, frameCount: spec.frameCount, loop: spec.loop)
            : IdleSpriteTiming.posterIndex
        IdleSpriteView(url: url, spec: spec, frameIndex: index).id(url)
    }

    @ViewBuilder
    private func lottieBody(_ url: URL, _ plan: IdlePlaybackPlan) -> some View {
        // One TimelineView at most: a 5 s heartbeat for inactivity detection (nothing when that is disabled).
        if frozen != nil {
            makeLottie(url, plan)
        } else {
            TimelineView(IdleClockSchedule(interval: controller.clockInterval)) { ctx in
                let _ = controller.noteTick(ctx.date)
                makeLottie(url, controller.plan)
            }
        }
    }
}

enum IdleDefaults {
    /// Fixed seed: the eyes blink on the same script every launch (deterministic, testable); tests inject others.
    static let eyesSeed: UInt64 = 0xA701_1E00
}

/// Eyes schedules are generated once per seed (a few hundred Doubles) and reused by every frame.
enum IdleEyesScheduleCache {
    nonisolated(unsafe) private static var cache: [UInt64: IdleEyesSchedule] = [:]
    private static let lock = NSLock()
    static func schedule(seed: UInt64) -> IdleEyesSchedule {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[seed] { return hit }
        let s = IdleEyesSchedule(seed: seed)
        if cache.count > 16 { cache.removeAll() }
        cache[seed] = s
        return s
    }
}
