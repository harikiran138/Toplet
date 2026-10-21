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

// Animated building blocks. Every effect reads `\.agentsMotion` and degrades as described in AgentsMotion.swift.

// MARK: - Status orb (breathing / attention pulse / symbol morph)

struct AgentsOrb: View {
    let status: SessionStatus
    var dim = false
    /// "Finished since you last looked": the orb morphs into a green checkmark and stays until acknowledged.
    var finished = false
    /// Test seam for film strips: render the morph from this status to `status` using the frozen clock.
    var morphFrom: SessionStatus?
    var size: CGFloat = 14

    @Environment(\.agentsMotion) private var m

    private func symbol(_ s: SessionStatus) -> String {
        switch s {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        default: return "circle.fill"
        }
    }

    private func glyphSize(_ s: SessionStatus) -> CGFloat { symbol(s) == "circle.fill" ? size * 0.6 : size * 0.9 }

    private func color(_ s: SessionStatus) -> Color { finished && s == .done ? AgentsTheme.success : s.dotColor }

    private var shown: SessionStatus { finished ? .done : status }
    private var attention: Bool { shown == .needsPermission || shown == .waitingInput }

    /// 0...1 breathing value for the running orb.
    private var breath: Double {
        guard shown == .running, m.animates else { return 0.5 }
        if let t = m.frozenTime { return AgentsPose.wave(t, period: 2.4) }
        return m.breathOn ? 1 : 0
    }

    var body: some View {
        ZStack {
            if attention && m.animates { AttentionRing(color: color(shown), size: size) }
            if let from = morphFrom, let t = m.frozenTime {
                let p = m.animates ? AgentsPose.spring(t, AgentsMotion.orbMorphSpring) : 1
                glyph(from).scaleEffect(max(0, 1 - p)).opacity(max(0, 1 - p * 1.4))
                glyph(shown).scaleEffect(max(0.01, p)).opacity(min(1, p * 1.4))
            } else {
                glyph(shown)
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(shown == .running && m.animates ? 0.92 + 0.16 * breath : 1)
                    .opacity((dim ? 0.55 : 1) * (shown == .running && m.animates ? 0.65 + 0.35 * breath : 1))
                    .animation(m.animates && !m.isFrozen ? AgentsMotion.breathe : nil, value: m.breathOn)
                    .animation(m.animates ? AgentsMotion.orbMorph : nil, value: shown)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func glyph(_ s: SessionStatus) -> some View {
        Image(systemName: symbol(s))
            .font(.system(size: glyphSize(s), weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color(s))
            .opacity(dim ? 0.55 : 1)
    }
}

/// Pose of the expanding attention ring, 0...1.
struct RingPose: View {
    let progress: Double
    let color: Color
    let size: CGFloat

    var body: some View {
        Circle()
            .strokeBorder(color.opacity((1 - progress) * 0.8), lineWidth: 1.5)
            .frame(width: size * (0.6 + 1.7 * progress), height: size * (0.6 + 1.7 * progress))
    }
}

/// Live: a KeyframeAnimator replays a 0.8 s expansion whenever the shared clock enters a new ring cycle.
/// Frozen (film strips): the closed-form pose.
struct AttentionRing: View {
    let color: Color
    let size: CGFloat
    @Environment(\.agentsMotion) private var m

    var body: some View {
        if let t = m.frozenTime {
            RingPose(progress: (t / 0.8).truncatingRemainder(dividingBy: 1), color: color, size: size)
        } else {
            KeyframeAnimator(initialValue: 0.0, trigger: m.ringCycle) { p in
                RingPose(progress: p, color: color, size: size)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0.0, duration: 0.001)
                    CubicKeyframe(1.0, duration: 0.8)
                }
            }
        }
    }
}

// MARK: - Shimmer for the "working" line

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    @Environment(\.agentsMotion) private var m

    func body(content: Content) -> some View {
        if active && m.animates {
            let step = m.isFrozen ? Int((m.frozenTime ?? 0) / AgentsMotionEnvironment.tickInterval) % 4 : m.shimmerStep
            content.overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Color.white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(24, geo.size.width * 0.45))
                        .offset(x: geo.size.width * (CGFloat(step) / 3 * 1.45 - 0.45))
                        .animation(step == 0 || m.isFrozen ? nil : .linear(duration: AgentsMotionEnvironment.tickInterval), value: step)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

extension View {
    /// A moving highlight over the glyphs of this view (current-tool line of running sessions).
    func agentsShimmer(active: Bool) -> some View { modifier(ShimmerModifier(active: active)) }
}

// MARK: - Progress ring chip (n/m)

struct ProgressChip: View {
    let done: Int
    let total: Int
    @Environment(\.agentsMotion) private var m

    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    private var complete: Bool { total > 0 && done == total }

    var body: some View {
        let tint: Color = complete ? AgentsTheme.success : Color.secondary
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(tint.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .agentsAnimation(AgentsMotion.ring, value: fraction, animates: m.animates)
            }
            .frame(width: 11, height: 11)
            Text(verbatim: "\(done)/\(total)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(done)))
                .agentsAnimation(AgentsMotion.ring, value: done, animates: m.animates)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .agentsInset(tint: complete ? AgentsTheme.success : nil, shape: .capsule)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(total) tasks done")
    }
}

// MARK: - Drawn checkbox

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.54))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.70))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.32))
        return p
    }
}

/// Circle that fills and draws its checkmark with a spring (trim), instead of cross-fading two symbols.
struct AgentsCheckbox: View {
    let isDone: Bool
    var size: CGFloat = 16
    @Environment(\.agentsMotion) private var m

    private var progress: Double {
        if let t = m.frozenTime, m.animates { return isDone ? AgentsPose.spring(t, AgentsMotion.checkSpring) : 0 }
        return isDone ? 1 : 0
    }

    var body: some View {
        let p = progress
        ZStack {
            Circle().strokeBorder(Color.secondary, lineWidth: 1.5).opacity(1 - min(1, p))
            Circle().fill(AgentsTheme.success).scaleEffect(max(0, p))
            CheckmarkShape()
                .trim(from: 0, to: min(1, max(0, p * 1.15 - 0.15)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .agentsAnimation(AgentsMotion.check, value: isDone, animates: m.animates && !m.isFrozen)
        .accessibilityHidden(true)
    }
}

// MARK: - Count pill (numeric transition + symbol bounce)

struct CountPill: View {
    let count: Int
    let word: String
    let color: Color
    @Environment(\.agentsMotion) private var m

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .symbolEffect(.bounce, options: .nonRepeating, value: m.animates ? count : 0)
            Text(verbatim: "\(count)")
                .contentTransition(.numericText(value: Double(count)))
            Text(verbatim: word)
        }
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .agentsInset(tint: color, shape: .capsule)
        .fixedSize()
        .agentsAnimation(AgentsMotion.rowMorph, value: count, animates: m.animates)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(word)")
    }
}

/// Keyframe bounce of a badge whenever `trigger` changes (new approval arrived).
struct BadgeBounce<Content: View>: View {
    let trigger: Int
    @ViewBuilder var content: () -> Content
    @Environment(\.agentsMotion) private var m

    private struct Pose { var scale = 1.0; var lift = 0.0 }

    var body: some View {
        if m.animates && !m.isFrozen {
            KeyframeAnimator(initialValue: Pose(), trigger: trigger) { pose in
                content().scaleEffect(pose.scale).offset(y: pose.lift)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.35, duration: 0.14, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
                }
                KeyframeTrack(\.lift) {
                    CubicKeyframe(-4, duration: 0.12)
                    SpringKeyframe(0, duration: 0.5, spring: .bouncy)
                }
            }
        } else {
            content()
        }
    }
}

// MARK: - Ambient glow behind the NEEDS YOU strip

struct AttentionGlow: View {
    let tint: Color
    @Environment(\.agentsMotion) private var m

    var body: some View {
        let step = m.animates ? m.driftStep : 0
        let wob = Float(step % 2 == 0 ? 0.06 : -0.06)
        ZStack {
            if #available(macOS 15.0, *) {
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [0.5 + wob, 0], [1, 0],
                        [0, 0.5 - wob], [0.5 - wob, 0.5 + wob], [1, 0.5 + wob],
                        [0, 1], [0.5 + wob, 1], [1, 1]
                    ],
                    colors: [
                        tint.opacity(0.0), tint.opacity(0.5), tint.opacity(0.0),
                        tint.opacity(0.35), tint.opacity(0.7), tint.opacity(0.3),
                        tint.opacity(0.0), tint.opacity(0.45), tint.opacity(0.0)
                    ]
                )
            } else {
                ZStack {
                    RadialGradient(colors: [tint.opacity(0.55), .clear], center: UnitPoint(x: 0.5 + Double(wob), y: 0.5), startRadius: 0, endRadius: 260)
                    LinearGradient(colors: [tint.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .blur(radius: 24)
        .mask { RoundedRectangle(cornerRadius: 48, style: .continuous).padding(28).blur(radius: 24) }   // no hard edge at the strip bounds
        .opacity(0.4)
        .animation(m.animates && !m.isFrozen ? AgentsMotion.drift : nil, value: step)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons: press squish and pointer-hover lift

final class AgentsHoverModel: ObservableObject {
    @Published var isHovering = false
}

struct AgentsStyledButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: AgentsButtonStyle.Kind
    let tint: Color

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.agentsMotion) private var m
    @StateObject private var hover = AgentsHoverModel()

    var body: some View {
        let pressed = configuration.isPressed
        let lifted = hover.isHovering && isEnabled
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .link ? 4 : 12)
            .frame(minHeight: AgentsTheme.minTarget)
            .background(background.opacity(pressed ? 0.7 : 1), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(lifted && kind != .link ? 0.3 : 0), lineWidth: 0.75))
            .brightness(lifted && !m.animates ? 0.08 : 0)
            .scaleEffect(m.animates ? (pressed ? 0.96 : (lifted ? 1.02 : 1)) : 1)
            .agentsAnimation(AgentsMotion.press, value: pressed, animates: m.animates)
            .agentsAnimation(AgentsMotion.hover, value: lifted, animates: m.animates)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule(style: .continuous))
            .onHover { hover.isHovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .destructive: return Color(red: 1.0, green: 0.55, blue: 0.5)
        case .quiet: return Color.primary
        case .link: return tint
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return tint
        case .destructive: return AgentsTheme.danger.opacity(0.18)
        case .quiet: return Color.white.opacity(0.12)
        case .link: return .clear
        }
    }
}
