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

// Shared surface, motion and token helpers for the notch notification UI and its settings sections.
// Generalised from AtollAgents/UI/AgentsSurface.swift + AgentsMotion.swift (same design language, same paths) under a
// NotchUI prefix, so the app can compile both modules side by side and neither depends on the other.
//
//   .notchGlass(tint:shape:interactive:id:in:)   container-level surface (cards, boxes, standalone controls)
//   .notchInset(tint:shape:)                      flat fill for things INSIDE a glass container (no glass on glass)
//   NotchUIGlassGroup(spacing:)                   GlassEffectContainer on macOS 26+ so neighbours blend and morph
//
// Surface paths, decided per element in this order:
//   1. Reduce Transparency        -> opaque fill + hairline, no blur
//   2. macOS 26+ (Liquid Glass)   -> glassEffect(_:in:), tint through .regular.tint, .interactive() when tappable
//   3. macOS 14.6 ... 25          -> ultra-thin material + 0.5 pt hairline + soft top highlight
// `#available` is the only link to the new API (deployment target 14.6). Increase Contrast strengthens strokes everywhere.

enum NotchUISurfaceMode: String { case auto, forceGlass, forceFallback }

enum NotchUIShape {
    case rounded(CGFloat)
    case capsule
    case circle
}

/// Test-only switches and counters. Production code never touches these.
enum NotchUISurfaceConfig {
    /// `ATOLL_NOTCH_UI_SURFACE=glass|fallback` forces a path (glass still needs macOS 26 at run time).
    static var mode: NotchUISurfaceMode = {
        switch ProcessInfo.processInfo.environment["ATOLL_NOTCH_UI_SURFACE"] {
        case "glass": return .forceGlass
        case "fallback": return .forceFallback
        default: return .auto
        }
    }()

    static var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var wantsGlass: Bool { mode != .forceFallback && glassAvailable }

    enum Path { case glass, material, opaque, inset }
    nonisolated(unsafe) private(set) static var counts: [Path: Int] = [:]
    static func bump(_ p: Path) { counts[p, default: 0] += 1 }
    static func resetCounts() { counts = [:] }
}

private struct NotchUIForceReduceTransparencyKey: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    /// Test-only override for Reduce Transparency (the system value is read-only).
    var notchUIForceReduceTransparency: Bool? {
        get { self[NotchUIForceReduceTransparencyKey.self] }
        set { self[NotchUIForceReduceTransparencyKey.self] = newValue }
    }
}

struct NotchUISurface: ViewModifier {
    var tint: Color?
    var shape: NotchUIShape
    var interactive: Bool
    var glassID: String?
    var namespace: Namespace.ID?

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.notchUIForceReduceTransparency) private var forcedReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var reduceTransparency: Bool { forcedReduceTransparency ?? systemReduceTransparency }
    private var highContrast: Bool { contrast == .increased }

    func body(content: Content) -> some View {
        switch shape {
        case .rounded(let r): surface(content, RoundedRectangle(cornerRadius: r, style: .continuous))
        case .capsule: surface(content, Capsule(style: .continuous))
        case .circle: surface(content, Circle())
        }
    }

    @ViewBuilder
    private func surface<S: InsettableShape>(_ content: Content, _ s: S) -> some View {
        if reduceTransparency {
            let _ = NotchUISurfaceConfig.bump(.opaque)
            content
                .background(s.fill(Color(white: 0.14)))
                .overlay(s.strokeBorder(Color.white.opacity(highContrast ? 0.55 : 0.18), lineWidth: highContrast ? 1 : 0.5))
                .overlay(tintStroke(s))
        } else if NotchUISurfaceConfig.wantsGlass {
            if #available(macOS 26.0, *) {
                glass(content, s)
            } else {
                material(content, s)
            }
        } else {
            material(content, s)
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func glass<S: InsettableShape>(_ content: Content, _ s: S) -> some View {
        let _ = NotchUISurfaceConfig.bump(.glass)
        let style: Glass = {
            var g = Glass.regular
            if let tint { g = g.tint(tint.opacity(0.32)) }
            if interactive { g = g.interactive() }
            return g
        }()
        let base = content
            .glassEffect(style, in: s)
            .overlay(s.strokeBorder(Color.white.opacity(highContrast ? 0.5 : 0), lineWidth: highContrast ? 1 : 0))
        if let glassID, let namespace {
            base.glassEffectID(glassID, in: namespace)
        } else {
            base
        }
    }

    @ViewBuilder
    private func material<S: InsettableShape>(_ content: Content, _ s: S) -> some View {
        let _ = NotchUISurfaceConfig.bump(.material)
        content
            .background {
                ZStack {
                    s.fill(Color.white.opacity(0.03))
                    s.fill(.ultraThinMaterial)
                    if let tint { s.fill(tint.opacity(0.14)) }
                }
            }
            .overlay(s.strokeBorder(Color.white.opacity(highContrast ? 0.5 : 0.12), lineWidth: highContrast ? 1 : 0.5))
            .overlay(
                s.inset(by: 0.75).strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(highContrast ? 0.3 : 0.16), Color.white.opacity(0)],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 0.75)
            )
            .overlay(tintStroke(s))
    }

    private func tintStroke<S: InsettableShape>(_ s: S) -> some View {
        s.strokeBorder((tint ?? .clear).opacity(tint == nil ? 0 : (highContrast ? 0.8 : 0.4)), lineWidth: 0.75)
    }
}

/// Flat fill for elements inside a glass container.
struct NotchUIInset: ViewModifier {
    var tint: Color?
    var shape: NotchUIShape
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        switch shape {
        case .rounded(let r): inset(content, RoundedRectangle(cornerRadius: r, style: .continuous))
        case .capsule: inset(content, Capsule(style: .continuous))
        case .circle: inset(content, Circle())
        }
    }

    private func inset<S: InsettableShape>(_ content: Content, _ s: S) -> some View {
        let _ = NotchUISurfaceConfig.bump(.inset)
        return content
            .background(s.fill((tint ?? Color.white).opacity(tint == nil ? 0.10 : 0.18)))
            .overlay(s.strokeBorder(Color.white.opacity(contrast == .increased ? 0.35 : 0), lineWidth: 0.5))
    }
}

extension View {
    func notchGlass(tint: Color? = nil, shape: NotchUIShape = .rounded(NotchUITheme.cardRadius), interactive: Bool = false,
                    id: String? = nil, in namespace: Namespace.ID? = nil) -> some View {
        modifier(NotchUISurface(tint: tint, shape: shape, interactive: interactive, glassID: id, namespace: namespace))
    }

    func notchInset(tint: Color? = nil, shape: NotchUIShape = .rounded(NotchUITheme.innerRadius)) -> some View {
        modifier(NotchUIInset(tint: tint, shape: shape))
    }

    /// `.buttonStyle(.glass)` / `.glassProminent` on macOS 26, bordered on older systems. For standalone buttons
    /// (the settings pages), not for buttons inside a `notchGlass` card.
    @ViewBuilder
    func notchSystemButton(prominent: Bool = false) -> some View {
        if NotchUISurfaceConfig.wantsGlass, #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

struct NotchUIGlassGroup<Content: View>: View {
    var spacing: CGFloat = 4
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.notchUIForceReduceTransparency) private var forcedReduceTransparency

    var body: some View {
        if !(forcedReduceTransparency ?? systemReduceTransparency), NotchUISurfaceConfig.wantsGlass, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Tokens

enum NotchUITheme {
    static let cardRadius: CGFloat = 16
    static let innerRadius: CGFloat = 8
    static let minTarget: CGFloat = 28            // HIG minimum hit target on macOS
    static let hairline = Color.white.opacity(0.10)
    static let settingsWidth: CGFloat = 700       // SettingsForm in SettingsView.swift

    static var accent: Color = .accentColor
    static var attention: Color = .orange
    static var danger: Color = .red
    static var success: Color = .green
}

// MARK: - Motion
//
// Budget rules (this runs inside an always-on notch app):
//  - Nothing animates unless a notification is on screen: the notification host builds no tree at all when `current` is nil.
//  - ONE repeating clock exists: the TimelineView around the card, stepping every `tickInterval` (0.4 s). Its schedule yields
//    a single entry (no timer) unless the card is visible AND needs a repeating effect (critical pulse) AND motion is allowed.
//  - Everything else is a one-shot spring/transition, or a single GPU-driven linear animation (countdown hairline, marquee).
//  - Reduce Motion turns scale/offset/pulse/marquee/hairline into instant opacity or static content.
//  - `frozenTime` is a test seam: the snapshot harness pins the clock to a time `t` and every effect renders the closed-form
//    pose it would have at `t` (NotchUIPose), which is what makes film strips deterministic.

struct NotchUIMotion: Equatable {
    var isActive = true
    var reduceMotion = false
    var tick = 0
    var frozenTime: Double?

    static let tickInterval: Double = 0.4

    var animates: Bool { isActive && !reduceMotion }
    var isFrozen: Bool { frozenTime != nil }
    var ringCycle: Int { tick / 2 }              // critical pulse cycle, 0.8 s each

    static func tick(for date: Date) -> Int { Int((date.timeIntervalSinceReferenceDate / tickInterval).rounded(.down)) }
}

private struct NotchUIMotionKey: EnvironmentKey { static let defaultValue = NotchUIMotion(isActive: false) }
extension EnvironmentValues {
    var notchUIMotion: NotchUIMotion {
        get { self[NotchUIMotionKey.self] }
        set { self[NotchUIMotionKey.self] = newValue }
    }
}

struct NotchUITickSchedule: TimelineSchedule {
    var active: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard active else { return AnySequence([startDate]) }
        let step = NotchUIMotion.tickInterval
        let first = Date(timeIntervalSinceReferenceDate: (startDate.timeIntervalSinceReferenceDate / step).rounded(.down) * step)
        return AnySequence(sequence(first: first) { $0.addingTimeInterval(step) })
    }
}

enum NotchUIMotionTokens {
    static let arrive = Animation.spring(response: 0.45, dampingFraction: 0.62)
    static let morph = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let dismiss = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let snapBack = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let count = Animation.snappy(duration: 0.25)
    static let hover = Animation.snappy(duration: 0.2)

    // Spring parameters mirrored for the closed-form poses below.
    static let arriveSpring = (response: 0.45, damping: 0.62)
    static let morphSpring = (response: 0.42, damping: 0.78)
    static let dismissSpring = (response: 0.34, damping: 0.82)
}

enum NotchUIPose {
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

    /// Symbol bounce on arrival: a decaying scale kick (the live path uses `.symbolEffect(.bounce)`).
    static func bounce(_ t: Double) -> Double {
        guard t > 0 else { return 1 }
        return 1 + 0.32 * exp(-5.5 * t) * abs(sin(2 * Double.pi * t / 0.55))
    }
}

extension View {
    func notchAnimation<V: Equatable>(_ animation: Animation, value: V, animates: Bool) -> some View {
        self.animation(animates ? animation : nil, value: value)
    }
}

// MARK: - Text measurement (pure, no layout pass)

enum NotchUIText {
    static func width(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Collapses newlines/tabs so a one-line label really is one line.
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
    }
}
