/*
 * Toplet — based on Atoll (DynamicIsland)
 * Copyright (C) 2026 Toplet Contributors
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

/// Toplet's ship, drawn as vectors in one Canvas so it stays sharp from a 20 pt notch wing to a
/// large preview, and costs one draw call per frame. Original design: a round-bowed little boat
/// with a porthole "eye", a bow figurehead, two sails and a pennant. No external artwork.
struct ShipPalette: Equatable {
    var hull: Color
    var hullShade: Color
    var sail: Color
    var sailShade: Color
    var pennant: Color
    var wave: Color
    var eye: Color

    /// Deep-ocean default.
    static let harbor = ShipPalette(
        hull: Color(red: 0.16, green: 0.43, blue: 0.86), hullShade: Color(red: 0.09, green: 0.24, blue: 0.55),
        sail: Color(red: 0.96, green: 0.97, blue: 1.0), sailShade: Color(red: 0.78, green: 0.84, blue: 0.95),
        pennant: Color(red: 0.36, green: 0.86, blue: 0.95), wave: Color(red: 0.25, green: 0.66, blue: 1.0),
        eye: .white)
    /// Warm alternative appearance.
    static let sunset = ShipPalette(
        hull: Color(red: 0.86, green: 0.42, blue: 0.26), hullShade: Color(red: 0.55, green: 0.22, blue: 0.14),
        sail: Color(red: 1.0, green: 0.96, blue: 0.9), sailShade: Color(red: 0.95, green: 0.82, blue: 0.7),
        pennant: Color(red: 1.0, green: 0.78, blue: 0.3), wave: Color(red: 0.3, green: 0.6, blue: 0.9),
        eye: .white)
    /// Quiet monochrome appearance.
    static let ink = ShipPalette(
        hull: Color(white: 0.85), hullShade: Color(white: 0.55),
        sail: Color(white: 0.98), sailShade: Color(white: 0.75),
        pennant: Color(white: 0.9), wave: Color(white: 0.6), eye: .black)
}

enum ShipAppearance: String, CaseIterable, Identifiable {
    case harbor, sunset, ink
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var palette: ShipPalette {
        switch self {
        case .harbor: return .harbor
        case .sunset: return .sunset
        case .ink: return .ink
        }
    }
}

struct ShipView: View {
    var mood: ShipMood
    var palette: ShipPalette = .harbor
    /// When false the ship holds a still pose (reduce motion, low power, or resting after a burst).
    var animating: Bool
    /// Show the little badge (note, bolt, Zzz…) that names the mood. Off in very small slots.
    var showsBadge = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 24 fps is plenty for a slow float and halves the cost of the default 60.
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !animating || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let motion = ShipMotion.for(mood).adjusted(reduceMotion: reduceMotion || !animating, lowPower: false)
            Canvas { gc, size in
                draw(in: &gc, size: size, pose: motion.pose(at: t), time: t, moving: motion.animates)
            }
        }
        .aspectRatio(100.0 / 64.0, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(mood.accessibilityDescription)
    }

    // MARK: Drawing (100 × 64 design units)

    private func draw(in gc: inout GraphicsContext, size: CGSize, pose: (dy: Double, angle: Double, wave: Double), time: Double, moving: Bool) {
        let k = min(size.width / 100, size.height / 64)
        gc.translateBy(x: (size.width - 100 * k) / 2, y: (size.height - 64 * k) / 2)
        gc.scaleBy(x: k, y: k)

        drawWave(&gc, baseline: 50, amplitude: 1.6, phase: pose.wave + 0.35, opacity: 0.45)

        var ship = gc
        ship.translateBy(x: 52, y: 46 + pose.dy)
        ship.rotate(by: .degrees(-pose.angle))
        ship.translateBy(x: -52, y: -46)
        drawSails(&ship)
        drawHull(&ship)
        drawEye(&ship)

        drawWave(&gc, baseline: 53, amplitude: 2.0, phase: pose.wave, opacity: 0.9)
        if showsBadge { drawBadge(&gc, time: time, moving: moving) }
    }

    private func drawWave(_ gc: inout GraphicsContext, baseline: Double, amplitude: Double, phase: Double, opacity: Double) {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 64))
        for i in stride(from: 0.0, through: 100.0, by: 2.0) {
            let y = baseline + sin((i / 100 * 2 + phase) * 2 * .pi) * amplitude
            p.addLine(to: CGPoint(x: i, y: y))
        }
        p.addLine(to: CGPoint(x: 100, y: 64))
        p.closeSubpath()
        gc.fill(p, with: .color(palette.wave.opacity(opacity)))
    }

    private func drawHull(_ gc: inout GraphicsContext) {
        var hull = Path()
        hull.move(to: CGPoint(x: 10, y: 33))
        hull.addLine(to: CGPoint(x: 78, y: 33))
        hull.addCurve(to: CGPoint(x: 90, y: 28), control1: CGPoint(x: 84, y: 33), control2: CGPoint(x: 88, y: 31))   // rising bow
        hull.addCurve(to: CGPoint(x: 74, y: 50), control1: CGPoint(x: 93, y: 33), control2: CGPoint(x: 88, y: 48))   // full, round forefoot
        hull.addLine(to: CGPoint(x: 28, y: 50))
        hull.addCurve(to: CGPoint(x: 10, y: 33), control1: CGPoint(x: 18, y: 50), control2: CGPoint(x: 11, y: 43))
        hull.closeSubpath()
        gc.fill(hull, with: .linearGradient(Gradient(colors: [palette.hull, palette.hullShade]),
                                            startPoint: CGPoint(x: 50, y: 34), endPoint: CGPoint(x: 50, y: 50)))
        // Deck rail highlight.
        var rail = Path()
        rail.move(to: CGPoint(x: 11, y: 34.2)); rail.addLine(to: CGPoint(x: 79, y: 34.2))
        gc.stroke(rail, with: .color(.white.opacity(0.35)), lineWidth: 1)
        // Friendly figurehead: a small round knob on the bow.
        gc.fill(Path(ellipseIn: CGRect(x: 87.5, y: 24, width: 5, height: 5)), with: .color(palette.pennant))
    }

    private func drawSails(_ gc: inout GraphicsContext) {
        var mast = Path()
        mast.move(to: CGPoint(x: 48, y: 34)); mast.addLine(to: CGPoint(x: 48, y: 5))
        gc.stroke(mast, with: .color(palette.hullShade), lineWidth: 1.6)
        // Main sail billows toward the bow.
        var main = Path()
        main.move(to: CGPoint(x: 49.5, y: 7))
        main.addQuadCurve(to: CGPoint(x: 49.5, y: 31), control: CGPoint(x: 74, y: 18))
        main.closeSubpath()
        gc.fill(main, with: .linearGradient(Gradient(colors: [palette.sail, palette.sailShade]),
                                            startPoint: CGPoint(x: 50, y: 10), endPoint: CGPoint(x: 66, y: 28)))
        // Small aft sail.
        var aft = Path()
        aft.move(to: CGPoint(x: 46.5, y: 12))
        aft.addQuadCurve(to: CGPoint(x: 46.5, y: 31), control: CGPoint(x: 30, y: 24))
        aft.closeSubpath()
        gc.fill(aft, with: .color(palette.sailShade))
        // Pennant at the masthead.
        var pennant = Path()
        pennant.move(to: CGPoint(x: 48, y: 5)); pennant.addLine(to: CGPoint(x: 57, y: 7)); pennant.addLine(to: CGPoint(x: 48, y: 9.5))
        pennant.closeSubpath()
        gc.fill(pennant, with: .color(mood == .lowBattery ? .orange : (mood == .offline ? .gray : palette.pennant)))
    }

    /// The porthole is the ship's eye; its shape carries the mood when motion is off.
    private func drawEye(_ gc: inout GraphicsContext) {
        let c = CGPoint(x: 66, y: 41.5), r = 4.2
        gc.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(palette.eye.opacity(0.95)))
        gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(palette.hullShade), lineWidth: 1)
        let ink = GraphicsContext.Shading.color(palette.eye == .black ? .white : Color(red: 0.05, green: 0.1, blue: 0.22))
        switch mood {
        case .sleeping, .offline:
            var lid = Path(); lid.move(to: CGPoint(x: c.x - 2.6, y: c.y)); lid.addLine(to: CGPoint(x: c.x + 2.6, y: c.y))
            gc.stroke(lid, with: ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        case .greeting, .celebrating, .music:
            var smile = Path()
            smile.move(to: CGPoint(x: c.x - 2.4, y: c.y + 0.8))
            smile.addQuadCurve(to: CGPoint(x: c.x + 2.4, y: c.y + 0.8), control: CGPoint(x: c.x, y: c.y - 2.6))
            gc.stroke(smile, with: ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        case .lowBattery:
            gc.fill(Path(ellipseIn: CGRect(x: c.x - 1.6, y: c.y, width: 3.2, height: 2.2)), with: ink)
            var lid = Path(); lid.move(to: CGPoint(x: c.x - 2.8, y: c.y - 0.2)); lid.addLine(to: CGPoint(x: c.x + 2.8, y: c.y - 0.2))
            gc.stroke(lid, with: ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        case .hover, .attentive, .alert:
            // Looking up and ahead, toward the pointer or the timer.
            gc.fill(Path(ellipseIn: CGRect(x: c.x - 0.6, y: c.y - 2.6, width: 2.8, height: 2.8)), with: ink)
        default:
            gc.fill(Path(ellipseIn: CGRect(x: c.x - 1.4, y: c.y - 1.4, width: 2.8, height: 2.8)), with: ink)
        }
    }

    private var badgeSymbol: String? {
        switch mood {
        case .music: return "music.note"
        case .charging: return "bolt.fill"
        case .lowBattery: return "battery.25percent"
        case .sailing: return "arrow.down.circle.fill"
        case .celebrating: return "sparkles"
        case .attentive: return "timer"
        case .alert: return "bell.fill"
        case .offline: return "wifi.slash"
        case .sleeping: return "zzz"
        case .greeting: return "hand.wave.fill"
        case .idle, .hover: return nil
        }
    }

    private var badgeColor: Color {
        switch mood {
        case .charging: return .green
        case .lowBattery, .alert: return .orange
        case .celebrating: return .yellow
        case .offline, .sleeping: return Color(white: 0.75)
        default: return palette.pennant
        }
    }

    private func drawBadge(_ gc: inout GraphicsContext, time: Double, moving: Bool) {
        guard let name = badgeSymbol else { return }
        let lift = moving ? sin(time * 2.4) * 1.5 : 0
        var symbol = gc.resolve(Image(systemName: name))
        symbol.shading = .color(badgeColor)
        let side = 15.0
        gc.draw(symbol, in: CGRect(x: 6, y: 4 + lift, width: side, height: side))
    }
}
