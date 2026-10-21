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

// Offscreen rendering helpers: ImageRenderer (no window, no screen-capture permission) for pure drawing, and an
// NSHostingView in a borderless window for views that load asynchronously (sprite sheets).

@MainActor var snapshotOutDir = "/tmp/atoll-idle-ui"

@MainActor
func renderBitmap<V: View>(_ view: V, size: CGSize, scale: CGFloat = 4, background: Color = .black) -> NSBitmapImageRep? {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(background))
    renderer.scale = scale
    renderer.proposedSize = ProposedViewSize(size)
    guard let cg = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: cg)
}

@MainActor
func renderHosted<V: View>(_ view: V, size: CGSize, settle: TimeInterval = 0.5) -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.black))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    window.contentView = nil
    return rep
}

func pngData(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:]) ?? Data() }

@MainActor
func saveBitmap(_ rep: NSBitmapImageRep, _ name: String) -> Bool {
    let url = URL(fileURLWithPath: snapshotOutDir).appendingPathComponent(name + ".png")
    do { try pngData(rep).write(to: url); return true } catch { return false }
}

// MARK: Pixel measurements

struct Ink {
    var pixels = 0
    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
    var sumX = 0.0, sumY = 0.0
    var brightness = 0.0
    var isEmpty: Bool { pixels == 0 }
    var width: Int { pixels == 0 ? 0 : maxX - minX + 1 }
    var height: Int { pixels == 0 ? 0 : maxY - minY + 1 }
    var centroidX: Double { pixels == 0 ? 0 : sumX / Double(pixels) }
    var centroidY: Double { pixels == 0 ? 0 : sumY / Double(pixels) }
}

/// Pixels brighter than `threshold` (0...255 on the max channel) over the black background.
func measureInk(_ rep: NSBitmapImageRep, threshold: Int = 40) -> Ink {
    var ink = Ink()
    guard let data = rep.bitmapData else { return ink }
    let w = rep.pixelsWide, h = rep.pixelsHigh, spp = rep.samplesPerPixel, bpr = rep.bytesPerRow
    for y in 0..<h {
        let row = data + y * bpr
        for x in 0..<w {
            let p = row + x * spp
            let m = max(Int(p[0]), Int(p[1]), Int(p[2]))
            if m > threshold {
                ink.pixels += 1
                ink.minX = min(ink.minX, x); ink.maxX = max(ink.maxX, x)
                ink.minY = min(ink.minY, y); ink.maxY = max(ink.maxY, y)
                ink.sumX += Double(x); ink.sumY += Double(y)
                ink.brightness += Double(m)
            }
        }
    }
    return ink
}

func pixelRGB(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
    guard let data = rep.bitmapData, x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return (0, 0, 0) }
    let p = data + y * rep.bytesPerRow + x * rep.samplesPerPixel
    return (Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255)
}

// MARK: Film strips

struct FilmFrame {
    var label: String
    var rep: NSBitmapImageRep
}

/// Lays frames out in a labelled grid and writes one PNG.
@MainActor
func composeStrip(_ frames: [FilmFrame], columns: Int, scale: CGFloat = 1, name: String, title: String) -> Bool {
    guard let first = frames.first else { return false }
    let fw = CGFloat(first.rep.pixelsWide) * scale, fh = CGFloat(first.rep.pixelsHigh) * scale
    let gap: CGFloat = 10, labelH: CGFloat = 20, titleH: CGFloat = 26
    let rows = Int((Double(frames.count) / Double(columns)).rounded(.up))
    let width = CGFloat(columns) * fw + CGFloat(columns + 1) * gap
    let height = titleH + CGFloat(rows) * (fh + labelH + gap) + gap
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor(white: 0.2, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
    (title as NSString).draw(at: NSPoint(x: gap, y: height - titleH + 5), withAttributes: attrs)
    for (i, f) in frames.enumerated() {
        let col = i % columns, row = i / columns
        let x = gap + CGFloat(col) * (fw + gap)
        let top = titleH + CGFloat(row) * (fh + labelH + gap)
        let y = height - top - labelH - fh
        f.rep.draw(in: NSRect(x: x, y: y, width: fw, height: fh))
        (f.label as NSString).draw(at: NSPoint(x: x, y: y - labelH + 4), withAttributes: attrs)
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return false }
    return saveBitmap(rep, name)
}
