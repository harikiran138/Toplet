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

// Native, procedural idle presets drawn with SwiftUI Canvas. No assets, no downloads, no libraries.
// The view is a pure function of an `IdlePresetFrame` (decided by `IdlePresetFramer` from the playback plan and the
// clock), so the offscreen snapshot harness can render any frame without a TimelineView or a timer.

struct IdlePresetStyle: Equatable {
    var primary = Color.white
    var accent = Color(red: 0.55, green: 0.82, blue: 1.0)
    static let standard = IdlePresetStyle()
}

struct IdlePresetCanvas: View {
    let frame: IdlePresetFrame
    var style = IdlePresetStyle.standard

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            switch frame {
            case .breathing(let pose): Self.drawBreathing(pose, in: &ctx, size: size, style: style)
            case .pulse(let rings): Self.drawPulse(rings, in: &ctx, size: size, style: style)
            case .eyes(let state): Self.drawEyes(state, in: &ctx, size: size, style: style)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Breathing: a soft orb with a faint ring, scale and opacity on a 4 s cosine

    static func drawBreathing(_ pose: IdleBreathingPose, in ctx: inout GraphicsContext, size: CGSize, style: IdlePresetStyle) {
        let r = min(size.width, size.height) / 2
        guard r > 0 else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let ringR = r * 0.88 * pose.ringScale
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2)),
                   with: .color(style.accent.opacity(pose.ringOpacity)), lineWidth: max(0.6, r * 0.08))
        let orbR = r * 0.78 * pose.orbScale
        let orb = Path(ellipseIn: CGRect(x: c.x - orbR, y: c.y - orbR, width: orbR * 2, height: orbR * 2))
        let gradient = Gradient(colors: [style.primary.opacity(pose.orbOpacity),
                                         style.accent.opacity(pose.orbOpacity * 0.85),
                                         style.accent.opacity(pose.orbOpacity * 0.25)])
        ctx.fill(orb, with: .radialGradient(gradient, center: CGPoint(x: c.x - orbR * 0.2, y: c.y - orbR * 0.25),
                                            startRadius: 0, endRadius: orbR * 1.15))
    }

    // MARK: Pulse: a steady core with expanding ripples

    static func drawPulse(_ rings: [IdlePulseRing], in ctx: inout GraphicsContext, size: CGSize, style: IdlePresetStyle) {
        let r = min(size.width, size.height) / 2
        guard r > 0 else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        for ring in rings where ring.opacity > 0.003 {
            let rr = r * 0.97 * ring.scale
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                       with: .color(style.accent.opacity(ring.opacity)), lineWidth: max(0.6, r * ring.lineWidth))
        }
        let core = r * 0.2
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)),
                 with: .color(style.primary.opacity(0.95)))
    }

    // MARK: Eyes: two rounded eyes, blink = vertical scale, glance = horizontal shift, squint = flattened lids

    static func drawEyes(_ state: IdleEyeState, in ctx: inout GraphicsContext, size: CGSize, style: IdlePresetStyle) {
        guard size.width > 0, size.height > 0 else { return }
        let eyeW = min(size.width * 0.27, size.height * 0.62)
        let eyeH = min(size.height * 0.78, eyeW * 1.65)
        let gap = size.width * 0.14
        let shift = state.gazeX * size.width * 0.07
        let cy = size.height / 2
        let h = max(eyeH * state.openness, max(1.1, eyeH * 0.07))      // closed eyes stay a thin line
        for sign in [-1.0, 1.0] {
            let cx = size.width / 2 + sign * (gap / 2 + eyeW / 2) + shift
            let rect = CGRect(x: cx - eyeW / 2, y: cy - h / 2, width: eyeW, height: h)
            var layer = ctx
            if state.squint > 0.01 {
                // Flatten the top edge like a raised cheek.
                let cut = h * 0.34 * state.squint
                layer.clip(to: Path(CGRect(x: rect.minX - 1, y: rect.minY + cut, width: rect.width + 2, height: rect.height)))
            }
            layer.fill(Path(roundedRect: rect, cornerRadius: min(eyeW, h) / 2), with: .color(style.primary.opacity(0.96)))
        }
    }
}
