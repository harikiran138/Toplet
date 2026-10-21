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

// One surface for elements inside the open notch, following the same three paths as the Agents
// UI (AgentsSurface.swift) so every tab looks like one app:
//   Reduce Transparency -> opaque fill + hairline
//   macOS 26+           -> Liquid Glass (.glassEffect), interactive for tappable elements
//   earlier macOS       -> ultra-thin material + hairline + soft top highlight
// The notch keeps its own black body; this is for the cards and controls drawn on it.

struct NotchSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var highContrast: Bool { contrast == .increased }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(tint.map { $0.opacity(0.35) } ?? Color(white: 0.14)))
                .overlay(shape.strokeBorder(Color.white.opacity(highContrast ? 0.55 : 0.18), lineWidth: highContrast ? 1 : 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(highContrast ? 0.5 : 0), lineWidth: highContrast ? 1 : 0))
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(Color.white.opacity(0.03))
                        shape.fill(.ultraThinMaterial)
                        if let tint { shape.fill(tint.opacity(0.18)) }
                    }
                }
                .overlay(shape.strokeBorder(Color.white.opacity(highContrast ? 0.5 : 0.12), lineWidth: highContrast ? 1 : 0.5))
                .overlay(
                    shape.inset(by: 0.75).strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(highContrast ? 0.3 : 0.16), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 0.75)
                )
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(0.35)) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    func notchSurface(cornerRadius: CGFloat = 12, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(NotchSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                              tint: tint, interactive: interactive))
    }

    func notchSurfaceCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(NotchSurface(shape: Capsule(style: .continuous), tint: tint, interactive: interactive))
    }
}

/// Groups glass elements so neighbours blend and morph on macOS 26; a plain container before that.
struct NotchSurfaceGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// macOS 26 softens scroll views with a blurred edge; inside the small notch that reads as
    /// smeared content, so the notch turns it off for every tab.
    @ViewBuilder
    func hidingScrollEdgeBlur() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}
