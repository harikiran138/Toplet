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

// The motion language of the Agents section, in one place. Pure SwiftUI + SF Symbols: no assets, no libraries.
//
// Budget rules (this runs inside an always-on notch app):
//  - ONE repeating clock exists: the TimelineView at the top of NotchAgentsView, stepping every `tickInterval` (0.4 s).
//    It feeds `AgentsMotionEnvironment.tick` down the view tree; breathing, the attention pulse, the shimmer sweep and
//    the mesh drift are all implicit Core Animation transitions started by a tick change, so SwiftUI does no per-frame
//    work (effective decorative rate: 2.5 Hz of body updates, far below the 30 fps cap).
//  - When `isActive` is false the schedule yields a single entry (no timer), every repeating effect is removed from the
//    tree (not hidden) and every `.animation` resolves to nil.
//  - Reduce Motion turns scale/offset/ring/shimmer/mesh drift into instant opacity or colour changes.
//  - Only rows that exist animate: the session list is a LazyVStack, so off-screen rows are not even instantiated.
//  - `frozenTime` is a test seam: the snapshot harness pins the animation clock to a time `t` and every effect renders
//    the closed-form pose it would have at `t` (see `AgentsPose`), which is what makes film strips deterministic.

struct AgentsMotionEnvironment: Equatable {
    var isActive = true
    var reduceMotion = false
    var tick = 0
    var frozenTime: Double?
    /// Test seam: the wall-clock "now" used for elapsed labels while the clock is frozen (deterministic frames).
    var frozenNow: Date?

    static let tickInterval: Double = 0.4

    var animates: Bool { isActive && !reduceMotion }
    var isFrozen: Bool { frozenTime != nil }
    var clockTime: Double { frozenTime ?? Double(tick) * Self.tickInterval }

    /// Live breathing state: flips every 1.2 s (3 ticks), eased over the same interval => 2.4 s full cycle.
    var breathOn: Bool { (tick / 3) % 2 == 0 }
    /// Shimmer sweep position, 0...3 over 1.6 s.
    var shimmerStep: Int { tick % 4 }
    /// Mesh drift target, advances every 4 s.
    var driftStep: Int { Int(clockTime / 4) }
    /// Attention ring cycle number (0.8 s each, 2 ticks).
    var ringCycle: Int { tick / 2 }

    static func tick(for date: Date) -> Int { Int((date.timeIntervalSinceReferenceDate / tickInterval).rounded(.down)) }
}

private struct AgentsMotionKey: EnvironmentKey {
    static let defaultValue = AgentsMotionEnvironment(isActive: false)
}

extension EnvironmentValues {
    var agentsMotion: AgentsMotionEnvironment {
        get { self[AgentsMotionKey.self] }
        set { self[AgentsMotionKey.self] = newValue }
    }
}

enum AgentsMotion {
    // Named springs and durations (one tuning per kind of motion).
    static let rowMorph = Animation.snappy(duration: 0.38, extraBounce: 0.12)
    static let cardDrop = Animation.spring(response: 0.45, dampingFraction: 0.62)
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.55)
    static let hover = Animation.snappy(duration: 0.2)
    static let check = Animation.spring(response: 0.38, dampingFraction: 0.6)
    static let ring = Animation.smooth(duration: 0.6)
    static let orbMorph = Animation.bouncy(duration: 0.45)
    static let breathe = Animation.easeInOut(duration: 1.2)
    static let drift = Animation.easeInOut(duration: 4)
    static let dropTarget = Animation.spring(response: 0.3, dampingFraction: 0.6)

    // Spring parameters mirrored for the closed-form poses below.
    static let rowMorphSpring = (response: 0.38, damping: 0.78)
    static let cardDropSpring = (response: 0.45, damping: 0.62)
    static let checkSpring = (response: 0.38, damping: 0.6)
    static let orbMorphSpring = (response: 0.45, damping: 0.7)
    static let dropTargetSpring = (response: 0.3, damping: 0.6)
}

/// Closed-form poses of the animations (used when the clock is frozen, i.e. in film strips).
enum AgentsPose {
    /// Underdamped spring step response from 0 to 1 (same model as SwiftUI's `.spring(response:dampingFraction:)`).
    static func spring(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        if damping >= 1 { return 1 - (1 + omega * t) * exp(-omega * t) }
        let wd = omega * (1 - damping * damping).squareRoot()
        let decay = exp(-damping * omega * t)
        return 1 - decay * (cos(wd * t) + (damping * omega / wd) * sin(wd * t))
    }

    static func spring(_ t: Double, _ p: (response: Double, damping: Double)) -> Double { spring(t, response: p.response, damping: p.damping) }

    /// 0...1 cosine wave with the given period (breathing).
    static func wave(_ t: Double, period: Double) -> Double { 0.5 - 0.5 * cos(2 * Double.pi * t / period) }
}

extension View {
    /// `.animation` that resolves to nil when motion is off.
    func agentsAnimation<V: Equatable>(_ animation: Animation, value: V, animates: Bool) -> some View {
        self.animation(animates ? animation : nil, value: value)
    }
}

// MARK: - Card drop-in and detail reveal

/// 0 = hidden, 1 = shown. Springs overshoot past 1, which produces the small bounce.
struct DropPose: ViewModifier, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(min(1, max(0, progress * 1.8)))
            .scaleEffect(0.94 + 0.06 * progress, anchor: .top)
            .offset(y: -(1 - progress) * 20)
    }
}

struct RevealLayout: Layout {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = subviews.first?.sizeThatFits(proposal) ?? .zero
        return CGSize(width: s.width, height: s.height * max(0, progress))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Height reveal with fade, used for the expanded session detail and the approval detail box.
struct RevealPose: ViewModifier, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        RevealLayout(progress: progress) {
            content.opacity(min(1, max(0, progress)))
        }
        .clipped()
    }
}

extension AnyTransition {
    static func agentsDrop(animates: Bool) -> AnyTransition {
        guard animates else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: DropPose(progress: 0), identity: DropPose(progress: 1)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
        )
    }

    static func agentsReveal(animates: Bool) -> AnyTransition {
        guard animates else { return .opacity }
        return .modifier(active: RevealPose(progress: 0), identity: RevealPose(progress: 1))
    }
}
