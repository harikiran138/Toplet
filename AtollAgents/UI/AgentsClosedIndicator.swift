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

// A compact live-activity indicator for the CLOSED notch: one small glyph per active agent kind.
//
// SIZE CONTRACT (mirrors the other closed-notch wings, see Toplet/ContentView.swift `MusicLiveActivity`,
// `DynamicIslandFaceAnimation` and `IdleAnimationView().frame(width: sideSize, height: sideSize)`):
//   - height: the host passes the wing height = `vm.effectiveClosedNotchHeight - 12` (+12 while hovering), normally
//     18...32 pt. Each slot is a circle of that diameter, so a slot is `height` x `height`.
//   - width: `AgentsClosedIndicator.width(for:height:)` = n * height + (n - 1) * 4 with n = 1 or 2 agent kinds, i.e.
//     18...64 pt. When no agent is active the view (and `width(for:)`) is ZERO: the host hides the wing entirely.
//   - the badge for a count > 1 sits inside the slot's top-trailing corner, so nothing draws outside that rectangle.
// Behaviour: running = native breathing, needs permission/waiting = orange attention ring + count badge,
// finished-unseen = green check that the orb morphs into (spring) and stays until acknowledged, failed = red.
// Budgets: one TimelineView at 0.4 s steps that exists only while isActive and a running/attention kind exists
// (finished/failed are static); Reduce Motion => no scale/ring, instant colour; Reduce Transparency => opaque.

enum AgentsClosedState: Equatable {
    case running, attention, finished, failed

    var tint: Color {
        switch self {
        case .running: return AgentsTheme.success
        case .attention: return AgentsTheme.attention
        case .finished: return AgentsTheme.success
        case .failed: return AgentsTheme.danger
        }
    }

    var word: String {
        switch self {
        case .running: return "running"
        case .attention: return "needs permission"
        case .finished: return "finished"
        case .failed: return "failed"
        }
    }
}

struct AgentsClosedKind: Equatable, Identifiable {
    var kind: AgentKind
    var state: AgentsClosedState
    var count: Int                     // sessions in that state (badge shows it when > 1)
    var id: String { kind.rawValue }
}

struct AgentsClosedSummary: Equatable {
    var kinds: [AgentsClosedKind] = []
    var isEmpty: Bool { kinds.isEmpty }
    var animating: Bool { kinds.contains { $0.state == .running || $0.state == .attention } }

    /// Per agent kind the most urgent state wins: attention > failed > finished (unseen) > running.
    /// Kinds with nothing active (only idle/done-and-seen sessions) are left out.
    static func make(sessions: [AgentSession], pending: [PendingApproval]) -> AgentsClosedSummary {
        var out: [AgentsClosedKind] = []
        for kind in AgentKind.allCases {
            let mine = sessions.filter { $0.key.kind == kind }
            let attention = Set(mine.filter { $0.status == .needsPermission || $0.status == .waitingInput }.map(\.key))
                .union(pending.filter { $0.sessionKey.kind == kind }.map(\.sessionKey))
            if !attention.isEmpty { out.append(.init(kind: kind, state: .attention, count: attention.count)); continue }
            let failed = mine.filter { $0.status == .failed }.count
            if failed > 0 { out.append(.init(kind: kind, state: .failed, count: failed)); continue }
            let finished = mine.filter { $0.uiFinishedUnseen && ($0.status == .idle || $0.status == .done) }.count
            if finished > 0 { out.append(.init(kind: kind, state: .finished, count: finished)); continue }
            let running = mine.filter { $0.status == .running || $0.status == .starting }.count
            if running > 0 { out.append(.init(kind: kind, state: .running, count: running)) }
        }
        return AgentsClosedSummary(kinds: out)
    }

    var accessibilityText: String {
        kinds.map { k in "\(k.kind.displayName) \(k.state.word)" + (k.count > 1 ? " (\(k.count))" : "") }.joined(separator: ", ")
    }
}

struct AgentsClosedIndicator: View {
    let summary: AgentsClosedSummary
    var height: CGFloat = 20
    var isActive = true
    var onTap: () -> Void = {}
    /// Test hook: pins the animation clock / forces Reduce Motion (film strips).
    var motionOverride: AgentsMotionEnvironment?
    /// Test hook: render the morph from this state (film strips, frozen clock only).
    var morphFrom: AgentsClosedState?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let spacing: CGFloat = 4

    static func width(for summary: AgentsClosedSummary, height: CGFloat) -> CGFloat {
        let n = CGFloat(min(summary.kinds.count, 2))
        return n == 0 ? 0 : n * height + (n - 1) * spacing
    }

    private func motion(tick: Int) -> AgentsMotionEnvironment {
        if var o = motionOverride { o.isActive = o.isActive && isActive; return o }
        return AgentsMotionEnvironment(isActive: isActive, reduceMotion: reduceMotion, tick: tick, frozenTime: nil)
    }

    var body: some View {
        if summary.isEmpty {
            // Zero width: the host hides the wing. No clock, no tree.
            Color.clear.frame(width: 0, height: 0)
        } else {
            TimelineView(AgentsTickSchedule(active: isActive && summary.animating && motionOverride?.isFrozen != true)) { context in
                strip
                    .environment(\.agentsMotion, motion(tick: AgentsMotionEnvironment.tick(for: context.date)))
            }
            .environment(\.colorScheme, .dark)      // the closed notch is always black
            .frame(width: Self.width(for: summary, height: height), height: height)
        }
    }

    private var strip: some View {
        let shown = Array(summary.kinds.prefix(2))
        return Button(action: onTap) {
            AgentsGlassGroup(spacing: Self.spacing) {
                HStack(spacing: Self.spacing) {
                    ForEach(shown) { k in
                        ClosedSlot(item: k, diameter: height, morphFrom: morphFrom)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .help("Open the Agents tab")
        .accessibilityLabel("AI agents")
        .accessibilityValue(summary.accessibilityText)
        .accessibilityHint("Opens the Agents tab")
    }
}

private struct ClosedSlot: View {
    let item: AgentsClosedKind
    let diameter: CGFloat
    let morphFrom: AgentsClosedState?
    @Environment(\.agentsMotion) private var m

    private func symbol(_ s: AgentsClosedState) -> String {
        switch s {
        case .running: return AgentsTheme.symbol(for: item.kind)
        case .attention: return AgentsTheme.symbol(for: item.kind)
        case .finished: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private func tint(_ s: AgentsClosedState) -> Color { s == .running ? AgentsTheme.color(for: item.kind) : s.tint }

    private var breath: Double {
        guard item.state == .running, m.animates else { return 0.5 }
        if let t = m.frozenTime { return AgentsPose.wave(t, period: 2.4) }
        return m.breathOn ? 1 : 0
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if item.state == .attention && m.animates {
                    AttentionRing(color: AgentsTheme.attention, size: diameter * 0.62)
                }
                if let from = morphFrom, let t = m.frozenTime {
                    let p = m.animates ? AgentsPose.spring(t, AgentsMotion.orbMorphSpring) : 1
                    glyph(from).scaleEffect(max(0, 1 - p)).opacity(max(0, 1 - p * 1.4))
                    glyph(item.state).scaleEffect(max(0.01, p)).opacity(min(1, p * 1.4))
                } else {
                    glyph(item.state)
                        .contentTransition(.symbolEffect(.replace))
                        .scaleEffect(item.state == .running && m.animates ? 0.92 + 0.16 * breath : 1)
                        .opacity(item.state == .running && m.animates ? 0.65 + 0.35 * breath : 1)
                        .animation(m.animates && !m.isFrozen ? AgentsMotion.breathe : nil, value: m.breathOn)
                        .animation(m.animates ? AgentsMotion.orbMorph : nil, value: item.state)
                }
            }
            .frame(width: diameter, height: diameter)
            // The count badge is part of the glass element's content (flat, inside the slot), not a sibling drawn over glass.
            if item.count > 1 {
                Text(verbatim: "\(item.count)")
                    .font(.system(size: max(8, diameter * 0.4), weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: diameter * 0.42, minHeight: diameter * 0.42)
                    .background(Capsule(style: .continuous).fill(tint(item.state)))
                    .agentsAnimation(AgentsMotion.rowMorph, value: item.count, animates: m.animates)
            }
        }
        .frame(width: diameter, height: diameter)
        .agentsGlass(tint: tint(item.state), shape: .circle, interactive: true)
        .accessibilityHidden(true)
    }

    private func glyph(_ s: AgentsClosedState) -> some View {
        Image(systemName: symbol(s))
            .font(.system(size: diameter * 0.46, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint(s))
    }
}
