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

// Notification sneak peek for the notch: ONE view tree that morphs between
//   COMPACT   closed-notch wings: source glyph in the left wing, title (marquee when long) in the right wing, "+N" chip.
//             Height = closed notch height, glyph = height - 12, balanced wings (see NotificationCompactLayout).
//   EXPANDED  the notch grows downward into a rounded-bottom card (the battery "standard" pattern): app + time + dismiss in
//             the strip next to the physical notch, title, two-line preview (or "Content hidden"), Snooze / Open buttons.
// The morph is a single Animatable `expansion` (0...1) read by a custom Layout, so the shared glyph and title move instead of
// cross-fading, and the film strips can freeze it at any t. On macOS 26 the glyph tile, dismiss and buttons are Liquid Glass
// inside one GlassEffectContainer (they blend while the card morphs); older systems get the material fallback; Reduce
// Transparency gets opaque fills; Reduce Motion gets no scale/offset/pulse/marquee/hairline (instant state changes).
//
// Budget: nothing is built when no notification is visible (the host returns nothing); the only repeating clock is the
// critical pulse (0.4 s ticks, only while a critical card is on screen and motion is allowed); the countdown hairline and the
// marquee are single GPU-driven linear animations, not timers.

/// Test-only: freeze a one-shot motion at the pose it has at `motion.frozenTime`.
enum NotificationTestPhase: Equatable { case arriving, morph, dismissing }

enum NotificationRole: Hashable { case icon, appName, title, chip, time, dismiss, preview, snooze, primary }

enum NotificationTint {
    static func accent(_ p: NotificationPriority) -> Color? {
        switch p {
        case .critical: return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .high: return Color(red: 1.0, green: 0.62, blue: 0.04)
        case .normal, .low: return nil
        }
    }

    /// Glyph colour.
    static func glyph(_ p: NotificationPriority) -> Color {
        switch p {
        case .critical: return Color(red: 1.0, green: 0.42, blue: 0.40)
        case .high: return Color(red: 1.0, green: 0.72, blue: 0.30)
        case .normal: return Color.white.opacity(0.92)
        case .low: return Color.white.opacity(0.45)
        }
    }

    /// Title colour (critical and high are tinted, normal is neutral, low is dim).
    static func title(_ p: NotificationPriority) -> Color {
        switch p {
        case .critical: return Color(red: 1.0, green: 0.50, blue: 0.47)
        case .high: return Color(red: 1.0, green: 0.76, blue: 0.40)
        case .normal: return Color.white.opacity(0.95)
        case .low: return Color.white.opacity(0.50)
        }
    }
}

// MARK: - Morph layout

struct NotificationMorphFrame {
    var compact: CGRect
    var expanded: CGRect
    func rect(_ p: Double) -> CGRect {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(p) }
        return CGRect(x: mix(compact.minX, expanded.minX), y: mix(compact.minY, expanded.minY),
                      width: max(0, mix(compact.width, expanded.width)), height: max(0, mix(compact.height, expanded.height)))
    }
}

private struct NotificationRoleKey: LayoutValueKey { static let defaultValue: NotificationRole? = nil }

extension View {
    fileprivate func morphRole(_ role: NotificationRole) -> some View { layoutValue(key: NotificationRoleKey.self, value: role) }
}

struct NotificationMorphLayout: Layout, Animatable {
    var progress: Double
    var compact: CGSize
    var expanded: CGSize
    var frames: [NotificationRole: NotificationMorphFrame]

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: compact.width + (expanded.width - compact.width) * CGFloat(progress),
               height: compact.height + (expanded.height - compact.height) * CGFloat(progress))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for sv in subviews {
            guard let role = sv[NotificationRoleKey.self], let f = frames[role] else {
                sv.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
                continue
            }
            let r = f.rect(progress)
            sv.place(at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY), anchor: .topLeading,
                     proposal: ProposedViewSize(width: r.width, height: r.height))
        }
    }
}

struct NotificationSurfaceShape: Shape, Animatable {
    var progress: Double
    var compactBottom: CGFloat
    var top: CGFloat = 6
    var expandedBottom: CGFloat = 28

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = CGFloat(min(1, max(0, progress)))
        let b = compactBottom + (expandedBottom - compactBottom) * t
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: b, bottomTrailingRadius: b, topTrailingRadius: top,
                                      style: .continuous).path(in: rect)
    }
}

// MARK: - Poses (arrival drop-in and dismiss)

struct NotchUIDropPose: ViewModifier, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(min(1, max(0, progress * 1.8)))
            .scaleEffect(0.9 + 0.1 * progress, anchor: .top)
            .offset(y: -(1 - progress) * 26)
    }
}

/// 0 = in place, 1 = gone (swipe-away / removal).
struct NotchUIDismissPose: ViewModifier, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(max(0, 1 - progress * 1.15))
            .scaleEffect(1 - 0.06 * progress, anchor: .top)
            .offset(y: -34 * progress)
    }
}

extension AnyTransition {
    static func notchDrop(animates: Bool) -> AnyTransition {
        guard animates else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: NotchUIDropPose(progress: 0), identity: NotchUIDropPose(progress: 1)),
            removal: .modifier(active: NotchUIDismissPose(progress: 1), identity: NotchUIDismissPose(progress: 0))
        )
    }
}

// MARK: - Small drivers (one-shot, no repeating timers)

/// Counts up once, shortly after the card appears: triggers the symbol bounce and the haptic.
@MainActor
final class NotificationArrivalDriver: ObservableObject {
    @Published private(set) var token = 0
    private var scheduled = false

    func arrive() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.token += 1 }
    }
}

/// Runs the countdown hairline as ONE linear animation from the published `NotificationCountdown` (no timer).
@MainActor
final class NotificationCountdownDriver: ObservableObject {
    @Published private(set) var fraction: Double = 1
    private var lastKey: [Double] = []

    func apply(_ c: NotificationCountdown?, now: Date = Date()) {
        guard let c else { return }
        let key: [Double] = [c.duration, c.remaining, c.asOf.timeIntervalSince1970, c.isPaused ? 1.0 : 0.0]
        guard key != lastKey else { return }
        lastKey = key
        let rem = c.remaining(at: now)
        let f = c.fraction(at: now)
        if c.isPaused || rem <= 0.02 {
            withAnimation(.easeOut(duration: 0.12)) { fraction = f }
        } else {
            withAnimation(nil) { fraction = f }
            DispatchQueue.main.async { [weak self] in
                withAnimation(.linear(duration: rem)) { self?.fraction = 0 }
            }
        }
    }
}

@MainActor
final class NotificationMarqueeDriver: ObservableObject {
    @Published private(set) var phase: CGFloat = 0
    private var started = false

    func start(duration: Double) {
        guard !started else { return }
        started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) { self?.phase = 1 }
        }
    }
}

/// Single-line text that scrolls when it does not fit. Static (tail-truncated) under Reduce Motion or when inactive.
struct NotificationMarquee: View {
    let text: String
    let width: CGFloat
    let color: Color
    @Environment(\.notchUIMotion) private var m

    static let gap: CGFloat = 22
    static let speed: CGFloat = 32          // points per second

    var body: some View {
        let textW = NotchUIText.width(text, size: 12, weight: .semibold)
        if textW <= width + 0.5 || !m.animates {
            Text(verbatim: text).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
                .frame(width: width, alignment: .leading)
        } else {
            Scrolling(text: text, textW: textW, width: width, color: color)
        }
    }

    private struct Scrolling: View {
        let text: String
        let textW: CGFloat
        let width: CGFloat
        let color: Color
        @StateObject private var driver = NotificationMarqueeDriver()
        @Environment(\.notchUIMotion) private var m

        var body: some View {
            let loop = textW + NotificationMarquee.gap
            let duration = Double(loop / NotificationMarquee.speed)
            let phase: CGFloat = {
                if let t = m.frozenTime { return t < 0.9 ? 0 : CGFloat(((t - 0.9) / duration).truncatingRemainder(dividingBy: 1)) }
                return driver.phase
            }()
            HStack(spacing: NotificationMarquee.gap) {
                Text(verbatim: text); Text(verbatim: text)
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(color).lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: -phase * loop)
            .frame(width: width, alignment: .leading)
            .mask(
                LinearGradient(stops: [.init(color: phase > 0.001 ? .clear : .black, location: 0), .init(color: .black, location: 0.04),
                                       .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .onAppear { if !m.isFrozen { driver.start(duration: duration) } }
        }
    }
}

// MARK: - The view

struct NotificationSneakPeekView: View {
    let presentation: NotificationPresentation
    /// 0 = compact wings, 1 = expanded card. Animated by the host with the morph spring.
    var expansion: Double = 0
    var queued: Int = 0
    var closedHeight: CGFloat = 34
    var notchWidth: CGFloat = 185
    var countdown: NotificationCountdown?
    var supportsSnooze = false
    var isActive = true
    var onTap: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onPrimary: () -> Void = {}
    var onSnooze: () -> Void = {}
    /// Test hooks: pin the animation clock / force Reduce Motion, and freeze one one-shot motion.
    var motionOverride: NotchUIMotion?
    var testPhase: NotificationTestPhase?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNS
    @GestureState private var drag: CGSize = .zero
    @StateObject private var arrival = NotificationArrivalDriver()
    @StateObject private var countdownDriver = NotificationCountdownDriver()

    private var hasButtons: Bool { presentation.hasAction || supportsSnooze }

    private var compactLayout: NotificationCompactLayout {
        NotificationCompactLayout.make(title: presentation.title, queued: queued, closedHeight: closedHeight, notchWidth: notchWidth)
    }
    private var expandedSize: CGSize {
        NotificationExpandedLayout.size(closedHeight: closedHeight, notchWidth: notchWidth, hasButtons: hasButtons)
    }

    private func motion(tick: Int) -> NotchUIMotion {
        if var o = motionOverride { o.isActive = o.isActive && isActive; return o }
        return NotchUIMotion(isActive: isActive, reduceMotion: reduceMotion, tick: tick, frozenTime: nil)
    }

    private var clockActive: Bool {
        isActive && presentation.isCritical && !(motionOverride?.reduceMotion ?? reduceMotion) && motionOverride?.isFrozen != true
    }

    var body: some View {
        TimelineView(NotchUITickSchedule(active: clockActive)) { context in
            let m = motion(tick: NotchUIMotion.tick(for: context.date))
            card(m).environment(\.notchUIMotion, m)
        }
        .environment(\.colorScheme, .dark)         // the notch is always black
    }

    // MARK: Card

    @ViewBuilder
    private func card(_ m: NotchUIMotion) -> some View {
        let compact = compactLayout
        let expanded = expandedSize
        let t = m.frozenTime
        let p: Double = (testPhase == .morph && t != nil) ? (m.animates ? NotchUIPose.spring(t ?? 0, NotchUIMotionTokens.morphSpring) : 1) : expansion
        let frames = Self.frames(compact: compact, expanded: expanded, queued: queued, hasPrimary: presentation.hasAction,
                                 hasSnooze: supportsSnooze)
        let shape = NotificationSurfaceShape(progress: p, compactBottom: min(14, compact.outerHeight / 2))
        let dragOffset = CGSize(width: drag.width * 0.5, height: drag.height < 0 ? drag.height * 0.9 : drag.height * 0.12)
        let dragFade = max(0.35, 1 - Double(hypot(dragOffset.width, dragOffset.height)) / 140)
        let appearP: Double = (testPhase == .arriving && t != nil) ? (m.animates ? NotchUIPose.spring(t ?? 0, NotchUIMotionTokens.arriveSpring) : 1) : 1
        let dismissP: Double = (testPhase == .dismissing && t != nil) ? (m.animates ? min(1, NotchUIPose.spring(t ?? 0, NotchUIMotionTokens.dismissSpring)) : 1) : 0

        NotchUIGlassGroup(spacing: 10) {
            NotificationMorphLayout(progress: p, compact: compact.size, expanded: expanded, frames: frames) {
                iconCell(compact, m).morphRole(.icon)
                titleCell(m).morphRole(.title)
                if queued > 0 { chipCell(p).morphRole(.chip) }
                appNameCell(p).morphRole(.appName)
                timeCell(p).morphRole(.time)
                dismissCell(p).morphRole(.dismiss)
                previewCell(p).morphRole(.preview)
                if supportsSnooze { snoozeCell(p).morphRole(.snooze) }
                if presentation.hasAction { primaryCell(p).morphRole(.primary) }
            }
        }
        .background(shape.fill(Color.black))
        .overlay(alignment: .bottom) { hairline(m) }
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { onTap() }
        .gesture(
            DragGesture(minimumDistance: 8)
                .updating($drag) { v, state, _ in state = v.translation }
                .onEnded { v in
                    let predicted = hypot(v.predictedEndTranslation.width, v.predictedEndTranslation.height)
                    if hypot(v.translation.width, v.translation.height) > 36 || predicted > 110 { onDismiss() }
                }
        )
        .offset(dragOffset)
        .opacity(dragFade)
        .animation(m.animates ? NotchUIMotionTokens.snapBack : nil, value: drag == .zero)
        .modifier(NotchUIDropPose(progress: appearP))
        .modifier(NotchUIDismissPose(progress: dismissP))
        .sensoryFeedback(trigger: arrival.token) { _, new in
            guard new > 0 else { return nil }
            switch presentation.priority {
            case .critical: return .warning
            case .high: return .impact(weight: .medium)
            case .normal: return .alignment
            case .low: return nil
            }
        }
        .onAppear {
            if !m.isFrozen { arrival.arrive() }
            countdownDriver.apply(countdown)
        }
        .onChange(of: countdown) { _, new in countdownDriver.apply(new) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { onTap() }
        .accessibilityAction(named: NotificationAccessibility.dismissAction) { onDismiss() }
    }

    // MARK: Frames

    static func frames(compact c: NotificationCompactLayout, expanded e: CGSize, queued: Int, hasPrimary: Bool,
                       hasSnooze: Bool) -> [NotificationRole: NotificationMorphFrame] {
        let hc = c.outerHeight
        let side = c.iconSide
        let wc = c.totalWidth
        let we = e.width
        let sideY = (hc - side) / 2
        var out: [NotificationRole: NotificationMorphFrame] = [:]
        out[.icon] = NotificationMorphFrame(
            compact: CGRect(x: c.wingWidth - NotificationCompactLayout.innerPad - side, y: sideY, width: side, height: side),
            expanded: CGRect(x: 12, y: sideY, width: side, height: side))
        out[.title] = NotificationMorphFrame(
            compact: CGRect(x: c.wingWidth + c.centerWidth + NotificationCompactLayout.innerPad, y: (hc - 16) / 2, width: c.titleWidth, height: 16),
            expanded: CGRect(x: 16, y: hc + 6, width: we - 32, height: 18))
        let chipW = c.chipWidth
        let dismissE = CGRect(x: we - 12 - 22, y: (hc - 22) / 2, width: 22, height: 22)
        let dismissC = CGRect(x: wc - NotificationCompactLayout.outerPad - 22, y: (hc - 22) / 2, width: 22, height: 22)
        out[.dismiss] = NotificationMorphFrame(compact: dismissC, expanded: dismissE)
        var rightEdgeE = dismissE.minX - 6
        var rightEdgeC = dismissC.minX - 6
        if queued > 0 {
            let chipE = CGRect(x: rightEdgeE - chipW, y: (hc - 16) / 2, width: chipW, height: 16)
            let chipC = CGRect(x: wc - NotificationCompactLayout.outerPad - chipW, y: (hc - 16) / 2, width: chipW, height: 16)
            out[.chip] = NotificationMorphFrame(compact: chipC, expanded: chipE)
            rightEdgeE = chipE.minX - 6
            rightEdgeC = chipC.minX - 6
        }
        let timeW: CGFloat = 34
        out[.time] = NotificationMorphFrame(
            compact: CGRect(x: rightEdgeC - timeW, y: (hc - 14) / 2, width: timeW, height: 14),
            expanded: CGRect(x: rightEdgeE - timeW, y: (hc - 14) / 2, width: timeW, height: 14))
        let nameX = 12 + side + 6
        let nameW = max(0, (we - c.centerWidth) / 2 - nameX - 6)
        let nameRect = CGRect(x: nameX, y: (hc - 14) / 2, width: nameW, height: 14)
        out[.appName] = NotificationMorphFrame(compact: nameRect, expanded: nameRect)
        let previewRect = CGRect(x: 16, y: hc + 26, width: we - 32, height: 32)
        out[.preview] = NotificationMorphFrame(compact: previewRect, expanded: previewRect)
        let rowY = hc + 62
        var buttonRight = we - 16
        if hasPrimary {
            let r = CGRect(x: buttonRight - 64, y: rowY, width: 64, height: 24)
            out[.primary] = NotificationMorphFrame(compact: r, expanded: r)
            buttonRight = r.minX - 8
        }
        if hasSnooze {
            let r = CGRect(x: buttonRight - 70, y: rowY, width: 70, height: 24)
            out[.snooze] = NotificationMorphFrame(compact: r, expanded: r)
        }
        return out
    }

    // MARK: Cells

    /// Fades the expanded-only elements in during the last 40% of the morph (after the glyph has left their spot).
    private func reveal(_ p: Double) -> Double { min(1, max(0, (p - 0.6) / 0.4)) }

    private func iconCell(_ c: NotificationCompactLayout, _ m: NotchUIMotion) -> some View {
        let tint = NotificationTint.accent(presentation.priority)
        let side = c.iconSide
        let bounce: CGFloat = {
            guard m.animates, let t = m.frozenTime, testPhase == .arriving else { return 1 }
            return CGFloat(NotchUIPose.bounce(t))
        }()
        return ZStack {
            if presentation.isCritical && m.animates {
                NotificationPulseRing(color: NotificationTint.accent(.critical) ?? .red, size: side)
            }
            Group {
                if let bundle = presentation.bundleID, let icon = NotificationInstalledIcons.icon(bundle) {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: side * 0.8, height: side * 0.8)
                } else {
                    Image(systemName: presentation.symbol)
                }
            }
                .font(.system(size: max(9, side * 0.5), weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(NotificationTint.glyph(presentation.priority))
                .modifier(ArrivalBounce(token: arrival.token, enabled: m.animates && !m.isFrozen))
                .scaleEffect(bounce)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchGlass(tint: tint, shape: .circle, interactive: false, id: "icon", in: glassNS)
        .accessibilityHidden(true)
    }

    private func titleCell(_ m: NotchUIMotion) -> some View {
        GeometryReader { geo in
            NotificationMarquee(text: presentation.title, width: geo.size.width, color: NotificationTint.title(presentation.priority))
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .accessibilityHidden(true)
    }

    private func chipCell(_ p: Double) -> some View {
        Text(verbatim: "+\(queued)")
            .font(.system(size: 10, weight: .bold)).monospacedDigit()
            .contentTransition(.numericText(value: Double(queued)))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .notchInset(shape: .capsule)
            .animation(NotchUIMotionTokens.count, value: queued)
            .accessibilityHidden(true)
    }

    private func appNameCell(_ p: Double) -> some View {
        Text(verbatim: presentation.appName)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.white.opacity(0.62))
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .opacity(reveal(p))
            .accessibilityHidden(true)
    }

    private func timeCell(_ p: Double) -> some View {
        Text(verbatim: "now")
            .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.42)).lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .opacity(reveal(p))
            .accessibilityHidden(true)
    }

    private func dismissCell(_ p: Double) -> some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .notchGlass(shape: .circle, interactive: true, id: "dismiss", in: glassNS)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(reveal(p))
        .allowsHitTesting(p > 0.6)
        .accessibilityHidden(p <= 0.6)
        .accessibilityLabel(NotificationAccessibility.dismissLabel)
        .help("Dismiss")
    }

    @ViewBuilder
    private func previewCell(_ p: Double) -> some View {
        Group {
            if presentation.showsContentHidden {
                Label {
                    Text(verbatim: "Content hidden").italic()
                } icon: {
                    Image(systemName: "eye.slash")
                }
                .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.50))
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let preview = presentation.preview {
                Text(verbatim: preview)
                    .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Color.clear
            }
        }
        .opacity(reveal(p))
        .accessibilityHidden(true)
    }

    private func pillButton(_ title: String, tint: Color?, p: Double, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.95))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .notchGlass(tint: tint, shape: .capsule, interactive: true, id: id, in: glassNS)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(reveal(p))
        .allowsHitTesting(p > 0.6)
        .accessibilityHidden(p <= 0.6)
    }

    private func snoozeCell(_ p: Double) -> some View {
        pillButton("Snooze", tint: nil, p: p, id: "snooze", action: onSnooze).accessibilityLabel(NotificationAccessibility.snoozeLabel)
    }

    private func primaryCell(_ p: Double) -> some View {
        pillButton("Open", tint: NotificationTint.accent(presentation.priority) ?? NotchUITheme.accent, p: p, id: "primary", action: onPrimary)
            .accessibilityLabel(NotificationAccessibility.openLabel)
            .accessibilityHint(NotificationAccessibility.openHint)
    }

    // MARK: Countdown hairline

    @ViewBuilder
    private func hairline(_ m: NotchUIMotion) -> some View {
        if let countdown, m.animates {
            let f: Double = {
                if let t = m.frozenTime { return max(0, min(1, (countdown.remaining - t) / max(0.001, countdown.duration))) }
                return countdownDriver.fraction
            }()
            Capsule(style: .continuous)
                .fill((NotificationTint.accent(presentation.priority) ?? Color.white).opacity(0.55))
                .frame(height: 1.5)
                .scaleEffect(x: max(0.0001, f), y: 1, anchor: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Symbol bounce on arrival (live path). Separate so the effect only exists while motion is allowed.
private struct ArrivalBounce: ViewModifier {
    let token: Int
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.symbolEffect(.bounce, options: .nonRepeating, value: token) } else { content }
    }
}

/// Pulse ring behind the glyph of a critical notification (0.8 s cycles, driven by the card's single clock).
struct NotificationPulseRing: View {
    let color: Color
    let size: CGFloat
    @Environment(\.notchUIMotion) private var m

    private struct Pose: View {
        let progress: Double
        let color: Color
        let size: CGFloat
        var body: some View {
            Circle()
                .strokeBorder(color.opacity((1 - progress) * 0.85), lineWidth: 1.5)
                .frame(width: size * (0.8 + 0.8 * progress), height: size * (0.8 + 0.8 * progress))
        }
    }

    var body: some View {
        if let t = m.frozenTime {
            Pose(progress: (t / 0.8).truncatingRemainder(dividingBy: 1), color: color, size: size)
        } else {
            KeyframeAnimator(initialValue: 0.0, trigger: m.ringCycle) { p in
                Pose(progress: p, color: color, size: size)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0.0, duration: 0.001)
                    CubicKeyframe(1.0, duration: 0.8)
                }
            }
        }
    }
}

// MARK: - Host

/// Interaction state for the host: hover or keyboard focus expands the card. A reference type because `@State` is not
/// available to the offscreen build.
@MainActor
final class NotificationInteraction: ObservableObject {
    @Published var isExpanded = false
    func reset() { isExpanded = false }
}

/// The view the notch embeds. Builds NOTHING when there is no current notification (no tree, no clock, no timers).
///   - hover pauses the TTL (`setHovering`) and expands the card; leaving collapses it again
///   - tap runs the action when there is one, otherwise dismisses
///   - swipe away dismisses; the removal plays the dismiss pose with a spring
///   - arrival is announced to VoiceOver (critical at high priority)
struct NotificationSneakPeekHost<Center: NotificationPresenting>: View {
    @ObservedObject var center: Center
    var closedHeight: CGFloat
    var notchWidth: CGFloat
    var isActive = true
    var announcer = NotificationAnnouncer.system

    @StateObject private var interaction = NotificationInteraction()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let display = center.current {
                let presentation = NotificationPresentation(display)
                NotificationSneakPeekView(
                    presentation: presentation,
                    expansion: interaction.isExpanded ? 1 : 0,
                    queued: center.queuedCount,
                    closedHeight: closedHeight,
                    notchWidth: notchWidth,
                    countdown: center.countdown,
                    supportsSnooze: center.supportsSnooze,
                    isActive: isActive,
                    onTap: { presentation.hasAction ? center.performAction(display.id) : center.dismiss(display.id) },
                    onDismiss: { center.dismiss(display.id) },
                    onPrimary: { center.performAction(display.id) },
                    onSnooze: { center.snooze(display.id) })
                .id(display.id)
                .onHover { hovering in
                    interaction.isExpanded = hovering
                    center.setHovering(hovering)
                }
                .onDisappear { center.setHovering(false) }
                .transition(.notchDrop(animates: !reduceMotion))
            }
        }
        .animation(reduceMotion ? nil : NotchUIMotionTokens.arrive, value: center.current?.id)
        .animation(reduceMotion ? nil : NotchUIMotionTokens.morph, value: interaction.isExpanded)
        .onChange(of: center.current?.id, initial: true) { _, new in
            interaction.reset()
            guard new != nil, let display = center.current else { return }
            let p = NotificationPresentation(display)
            announcer.post(p.announcement, p.isCritical)
        }
    }
}

/// No downloading or arbitrary file access: resolve a verified source's installed app through Launch Services.
@MainActor
private enum NotificationInstalledIcons {
    static var images: [String: NSImage] = [:]
    static var missing: Set<String> = []
    static func icon(_ bundle: String) -> NSImage? {
        if let image = images[bundle] { return image }
        guard !missing.contains(bundle) else { return nil }
        if images.count + missing.count >= 256 { images.removeAll(); missing.removeAll() }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { missing.insert(bundle); return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        images[bundle] = image
        return image
    }
}
