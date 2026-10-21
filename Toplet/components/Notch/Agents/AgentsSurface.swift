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

// ONE place for every surface in the Agents UI.
//
//   .agentsGlass(tint:shape:interactive:id:in:)   container-level surface (cards, rows, banners, standalone controls)
//   .agentsInset(tint:shape:)                      flat fill for things that sit INSIDE a glass container (chips,
//                                                  inner buttons, code boxes): glass is never nested in glass
//   AgentsGlassGroup(spacing:)                     GlassEffectContainer on macOS 26+ so adjacent glass blends/morphs
//
// Paths (decided per element, in this order):
//   1. Reduce Transparency            -> opaque Color(white: 0.14) fill + hairline, no blur
//   2. macOS 26+ (Liquid Glass)       -> glassEffect(_:in:), tint via .regular.tint, .interactive() for tappable surfaces
//   3. macOS 14.6 ... 25 (fallback)   -> ultra-thin material + 0.5 pt white hairline + soft inner highlight
// Increase Contrast strengthens the strokes on every path. The notch keeps its own black body: surfaces here are the
// elements inside it, never a second background. `#available` is the only link to the new API (deployment target 14.6).

enum AgentsSurfaceMode: String { case auto, forceGlass, forceFallback }

enum AgentsShape {
    case rounded(CGFloat)
    case capsule
    case circle          // for square frames, where a capsule degenerates
}

/// Test-only switches and counters. Production code never touches these.
enum AgentsSurfaceConfig {
    /// `ATOLL_AGENTS_SURFACE=glass|fallback` forces a path (glass still needs macOS 26 at run time).
    static var mode: AgentsSurfaceMode = {
        switch ProcessInfo.processInfo.environment["ATOLL_AGENTS_SURFACE"] {
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
    /// Test-only: replace ScrollView by a clipped plain stack so ImageRenderer can rasterise the notch view.
    nonisolated(unsafe) static var snapshotStatic = false
    nonisolated(unsafe) private(set) static var counts: [Path: Int] = [:]
    static func bump(_ p: Path) { counts[p, default: 0] += 1 }
    static func resetCounts() { counts = [:] }
}

private struct AgentsForceReduceTransparencyKey: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    /// Test-only override for Reduce Transparency (the system value is read-only).
    var agentsForceReduceTransparency: Bool? {
        get { self[AgentsForceReduceTransparencyKey.self] }
        set { self[AgentsForceReduceTransparencyKey.self] = newValue }
    }
}

struct AgentsSurface: ViewModifier {
    var tint: Color?
    var shape: AgentsShape
    var interactive: Bool
    var glassID: String?
    var namespace: Namespace.ID?

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.agentsForceReduceTransparency) private var forcedReduceTransparency
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
            let _ = AgentsSurfaceConfig.bump(.opaque)
            content
                .background(s.fill(Color(white: 0.14)))
                .overlay(s.strokeBorder(Color.white.opacity(highContrast ? 0.55 : 0.18), lineWidth: highContrast ? 1 : 0.5))
                .overlay(tintStroke(s))
        } else if AgentsSurfaceConfig.wantsGlass {
            if #available(macOS 26.0, *) {
                glass(content, s)
            } else {
                material(content, s)
            }
        } else {
            material(content, s)
        }
    }

    // MARK: Liquid Glass (macOS 26+)

    @available(macOS 26.0, *)
    @ViewBuilder
    private func glass<S: InsettableShape>(_ content: Content, _ s: S) -> some View {
        let _ = AgentsSurfaceConfig.bump(.glass)
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

    // MARK: Material fallback (macOS 14.6 ... 25)

    @ViewBuilder
    private func material<S: InsettableShape>(_ content: Content, _ s: S) -> some View {
        let _ = AgentsSurfaceConfig.bump(.material)
        content
            .background {
                ZStack {
                    s.fill(Color.white.opacity(0.03))
                    s.fill(.ultraThinMaterial)
                    if let tint { s.fill(tint.opacity(0.14)) }
                }
            }
            .overlay(s.strokeBorder(Color.white.opacity(highContrast ? 0.5 : 0.12), lineWidth: highContrast ? 1 : 0.5))
            // soft inner highlight along the top edge
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
struct AgentsInset: ViewModifier {
    var tint: Color?
    var shape: AgentsShape
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        switch shape {
        case .rounded(let r): inset(content, RoundedRectangle(cornerRadius: r, style: .continuous))
        case .capsule: inset(content, Capsule(style: .continuous))
        case .circle: inset(content, Circle())
        }
    }

    private func inset<S: InsettableShape>(_ content: Content, _ s: S) -> some View {
        let _ = AgentsSurfaceConfig.bump(.inset)
        return content
            .background(s.fill((tint ?? Color.white).opacity(tint == nil ? 0.10 : 0.18)))
            .overlay(s.strokeBorder(Color.white.opacity(contrast == .increased ? 0.35 : 0), lineWidth: 0.5))
    }
}

extension View {
    /// Container-level surface. Interactive surfaces get the Liquid Glass touch response on macOS 26.
    func agentsGlass(tint: Color? = nil, shape: AgentsShape = .rounded(AgentsTheme.cardRadius), interactive: Bool = false,
                     id: String? = nil, in namespace: Namespace.ID? = nil) -> some View {
        modifier(AgentsSurface(tint: tint, shape: shape, interactive: interactive, glassID: id, namespace: namespace))
    }

    /// Flat fill for content that sits inside an `agentsGlass` container (no glass on glass).
    func agentsInset(tint: Color? = nil, shape: AgentsShape = .rounded(AgentsTheme.innerRadius)) -> some View {
        modifier(AgentsInset(tint: tint, shape: shape))
    }

    /// Pointer-hover highlight for list rows.
    func agentsHover(_ isHovered: Bool, radius: CGFloat = AgentsTheme.cardRadius) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(isHovered ? 0.07 : 0))
            .allowsHitTesting(false))
    }

    /// `.buttonStyle(.glass)` / `.glassProminent` on macOS 26, bordered on older systems. For standalone buttons
    /// (the settings page), not for buttons inside an `agentsGlass` card.
    @ViewBuilder
    func agentsSystemButton(prominent: Bool = false) -> some View {
        if AgentsSurfaceConfig.wantsGlass, #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// Wraps adjacent glass elements in a GlassEffectContainer (macOS 26+) so they sample together and can blend/morph.
struct AgentsGlassGroup<Content: View>: View {
    var spacing: CGFloat = 4
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.agentsForceReduceTransparency) private var forcedReduceTransparency

    var body: some View {
        if !(forcedReduceTransparency ?? systemReduceTransparency), AgentsSurfaceConfig.wantsGlass, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
