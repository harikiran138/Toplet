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

// Offscreen snapshot harness for the notch notification UI and the Notifications / Integrations settings sections.
// Renders fixture states to PNG (NSHostingView + cacheDisplay: no screen-capture permission; ImageRenderer for Liquid Glass)
// and asserts invariants. Build and run through AtollNotch/Tests/run_notch_ui.sh.

// MARK: - Assertions

@MainActor var failures = 0
@MainActor var passes = 0

@MainActor func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passes += 1; print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)  \(detail)") }
}

// MARK: - Rendering

let closedH: CGFloat = 34          // vm.effectiveClosedNotchHeight on a notched MacBook
let notchW: CGFloat = 185          // vm.closedNotchSize.width
let stageW: CGFloat = 560

/// Desktop + the physical notch outline (dashed) so wing alignment can be judged by eye. The view under test draws its own
/// black surface, as it does in the host.
struct NotchStage<Content: View>: View {
    let size: CGSize
    var showNotch = true
    let content: Content
    init(size: CGSize, showNotch: Bool = true, @ViewBuilder content: () -> Content) { self.size = size; self.showNotch = showNotch; self.content = content() }
    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.30)
            content.frame(maxWidth: .infinity, alignment: .top)
            if showNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                    .frame(width: notchW, height: closedH)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}

@MainActor var useImageRenderer = false
@MainActor var glassWarmWindow: NSWindow?

@MainActor
func warmUpGlass() {
    guard #available(macOS 26.0, *) else { return }
    let warm = NSHostingView(rootView: Text("x").padding(8).glassEffect())
    warm.frame = NSRect(x: 0, y: 0, width: 60, height: 40)
    let w = NSWindow(contentRect: warm.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = warm
    warm.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    glassWarmWindow = w
}

@MainActor
func bitmap<V: View>(_ view: V, size: CGSize, dark: Bool = true, settle: TimeInterval = 0.35, forceAppKit: Bool = false) -> NSBitmapImageRep? {
    if useImageRenderer && !forceAppKit {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(size)
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    window.contentView = nil
    return rep
}

@MainActor var outDir = "/tmp/atoll-notch-ui"

@MainActor
func save(_ rep: NSBitmapImageRep, _ name: String) -> Bool {
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name + ".png")
    do { try data.write(to: url); return true } catch { return false }
}

/// Fraction of pixels that differ noticeably from the pixel at (2, 2) (the stage colour). A blank render has ~0.
func inkFraction(_ rep: NSBitmapImageRep, threshold: CGFloat = 0.12) -> Double {
    guard let base = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB) else { return 0 }
    var diff = 0, total = 0
    let stepX = max(1, rep.pixelsWide / 220), stepY = max(1, rep.pixelsHigh / 160)
    var y = 0
    while y < rep.pixelsHigh {
        var x = 0
        while x < rep.pixelsWide {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                let d = abs(c.redComponent - base.redComponent) + abs(c.greenComponent - base.greenComponent) + abs(c.blueComponent - base.blueComponent) + abs(c.alphaComponent - base.alphaComponent)
                if d > threshold { diff += 1 }
                total += 1
            }
            x += stepX
        }
        y += stepY
    }
    return total == 0 ? 0 : Double(diff) / Double(total)
}

@MainActor
func sizeThatFits<V: View>(_ view: V, in proposal: CGSize) -> CGSize {
    NSHostingController(rootView: view).sizeThatFits(in: proposal)
}

let staticMotion = NotchUIMotion(isActive: false, reduceMotion: true, tick: 0, frozenTime: 0)

func compactView(_ d: NotificationDisplay, queued: Int = 0, height: CGFloat = closedH, countdown: NotificationCountdown? = nil,
                 motion: NotchUIMotion? = staticMotion, phase: NotificationTestPhase? = nil, isActive: Bool = true) -> NotificationSneakPeekView {
    NotificationSneakPeekView(presentation: NotificationPresentation(d), expansion: 0, queued: queued, closedHeight: height, notchWidth: notchW,
                              countdown: countdown, isActive: isActive, motionOverride: motion, testPhase: phase)
}

func expandedView(_ d: NotificationDisplay, queued: Int = 0, snooze: Bool = false, countdown: NotificationCountdown? = nil,
                  motion: NotchUIMotion? = staticMotion) -> NotificationSneakPeekView {
    NotificationSneakPeekView(presentation: NotificationPresentation(d), expansion: 1, queued: queued, closedHeight: closedH, notchWidth: notchW,
                              countdown: countdown, supportsSnooze: snooze, motionOverride: motion)
}

@MainActor
@discardableResult
func stageShot<V: View>(_ name: String, _ view: V, height: CGFloat, dark: Bool = true) -> NSBitmapImageRep? {
    let size = CGSize(width: stageW, height: height)
    guard let rep = bitmap(NotchStage(size: size) { view }, size: size, dark: dark, settle: 0.2) else { check("\(name): bitmap created", false); return nil }
    let ink = inkFraction(rep)
    check("\(name): non-empty render (ink \(String(format: "%.1f", ink * 100))%)", rep.pixelsWide > 0 && ink > 0.004)
    check("\(name): saved", save(rep, name))
    return rep
}

// MARK: - Accessibility scan

/// Collects every accessibility string (label, value, title, help) under an NSView, as a screen reader would see it.
@MainActor
func axStrings(_ root: NSObject, depth: Int = 0, into out: inout [String]) {
    guard depth < 14 else { return }
    guard let p = root as? NSAccessibilityProtocol else { return }
    for s in [p.accessibilityLabel(), p.accessibilityTitle(), p.accessibilityHelp(), (p.accessibilityValue() as? String)] {
        if let s, !s.isEmpty { out.append(s) }
    }
    var kids: [Any] = []
    if let c = p.accessibilityChildren() { kids += c }
    if let v = root as? NSView, kids.isEmpty { kids += v.subviews }
    for k in kids { if let o = k as? NSObject { axStrings(o, depth: depth + 1, into: &out) } }
}

@MainActor
func renderedAX<V: View>(_ view: V, size: CGSize) -> [String] {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    var out: [String] = []
    axStrings(host, into: &out)
    window.contentView = nil
    return out
}

// MARK: - Settings shots

@MainActor
func saveSplit(_ rep: NSBitmapImageRep, _ name: String, pieceHeight: Int = 1000) {
    guard let cg = rep.cgImage else { return }
    let scale = rep.pixelsHigh / max(1, Int(rep.size.height))
    let ph = pieceHeight * max(1, scale)
    var y = 0, i = 1
    while y < cg.height {
        let h = min(ph, cg.height - y)
        if let piece = cg.cropping(to: CGRect(x: 0, y: y, width: cg.width, height: h)) {
            _ = save(NSBitmapImageRep(cgImage: piece), "\(name)_part\(i)")
        }
        y += ph; i += 1
    }
}

@MainActor
func settingsShot(_ name: String, settings: NotificationSettings, history: [NotificationHistoryEntry] = [], dark: Bool, height: CGFloat) {
    func make() -> some View {
        Form {
            NotificationsSettingsSection(settings: .constant(settings), history: history, now: fixtureNow)
        }
        .formStyle(.grouped)
        .frame(width: NotchUITheme.settingsWidth, height: height)
    }
    let size = CGSize(width: NotchUITheme.settingsWidth, height: height)
    NotchUISurfaceConfig.resetCounts()
    guard let rep = bitmap(make(), size: size, dark: dark, settle: 0.5, forceAppKit: true) else { check("\(name): bitmap created", false); return }
    if NotchUISurfaceConfig.wantsGlass {
        check("\(name): glass path taken (\(NotchUISurfaceConfig.counts[.glass, default: 0]) glass surfaces)", NotchUISurfaceConfig.counts[.glass, default: 0] > 0)
        if inkFraction(rep) <= 0.01 {
            print("SKIP  \(name): Liquid Glass cannot be captured offscreen through the Form's AppKit host (blank bitmap); path asserted instead")
            return
        }
    }
    check("\(name): bitmap non-empty", rep.pixelsWide > 0 && inkFraction(rep, threshold: 0.03) > 0.01)
    check("\(name): saved", save(rep, name))
    saveSplit(rep, name)
    let fit = sizeThatFits(Form { NotificationsSettingsSection(settings: .constant(settings), history: history, now: fixtureNow) }.formStyle(.grouped),
                           in: CGSize(width: NotchUITheme.settingsWidth, height: 10_000))
    check("\(name): width \(Int(fit.width)) within \(Int(NotchUITheme.settingsWidth))", fit.width <= NotchUITheme.settingsWidth + 0.5)
}

@MainActor
func integrationsShot(_ name: String, dark: Bool, height: CGFloat = 1100, off: Set<NotchIntegration> = []) {
    func make() -> some View {
        Form {
            IntegrationsSettingsSection(isOn: { i in .constant(!off.contains(i)) })
        }
        .formStyle(.grouped)
        .frame(width: NotchUITheme.settingsWidth, height: height)
    }
    let size = CGSize(width: NotchUITheme.settingsWidth, height: height)
    NotchUISurfaceConfig.resetCounts()
    guard let rep = bitmap(make(), size: size, dark: dark, settle: 0.5, forceAppKit: true) else { check("\(name): bitmap created", false); return }
    if NotchUISurfaceConfig.wantsGlass {
        check("\(name): glass path taken (\(NotchUISurfaceConfig.counts[.glass, default: 0]) glass surfaces)", NotchUISurfaceConfig.counts[.glass, default: 0] > 0)
        if inkFraction(rep) <= 0.01 {
            print("SKIP  \(name): Liquid Glass cannot be captured offscreen through the Form's AppKit host (blank bitmap); path asserted instead")
            return
        }
    }
    check("\(name): bitmap non-empty", rep.pixelsWide > 0 && inkFraction(rep, threshold: 0.03) > 0.01)
    check("\(name): saved", save(rep, name))
    let fit = sizeThatFits(Form { IntegrationsSettingsSection(isOn: { _ in .constant(true) }) }.formStyle(.grouped), in: CGSize(width: NotchUITheme.settingsWidth, height: 10_000))
    check("\(name): width \(Int(fit.width)) within \(Int(NotchUITheme.settingsWidth))", fit.width <= NotchUITheme.settingsWidth + 0.5)
}

// MARK: - Main

@main
struct SnapshotMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if CommandLine.arguments.count > 1 { outDir = CommandLine.arguments[1] }
        if NotchUISurfaceConfig.mode == .forceGlass && !NotchUISurfaceConfig.glassAvailable {
            print("SKIP  glass surface run: needs macOS 26 or newer (fallback run still covers the layout)")
            exit(0)
        }
        print("Surface path: \(NotchUISurfaceConfig.wantsGlass ? "Liquid Glass (macOS 26)" : "material fallback")")
        useImageRenderer = NotchUISurfaceConfig.wantsGlass
        if useImageRenderer { warmUpGlass() }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        print("Output: \(outDir)")

        runModelAsserts()
        runContractAsserts()
        runStateShots()
        runSurfaceAsserts()
        runRedactionAsserts()
        runFilmStrips()
        runClockAsserts()
        runHostAsserts()

        // Settings sections
        var on = NotificationSettings(); on.enabled = true
        let off = NotificationSettings()
        settingsShot("ns_settings_enabled_dark", settings: on, history: historyFixture(), dark: true, height: 2900)
        settingsShot("ns_settings_enabled_light", settings: on, history: historyFixture(), dark: false, height: 2900)
        settingsShot("ns_settings_disabled_dark", settings: off, dark: true, height: 640)
        settingsShot("ns_settings_disabled_light", settings: off, dark: false, height: 640)
        var hideAll = on; hideAll.privacyMode = .hideAll; hideAll.focusPolicy = .silence
        hideAll.enabledSources = [.atoll, .calendar, .reminders]
        settingsShot("ns_settings_hideall_light", settings: hideAll, history: [], dark: false, height: 2900)
        var showAll = on; showAll.privacyMode = .off
        settingsShot("ns_settings_privacyoff_dark", settings: showAll, history: Array(historyFixture().prefix(2)), dark: true, height: 2900)
        integrationsShot("ni_integrations_dark", dark: true)
        integrationsShot("ni_integrations_light", dark: false, off: [.idle, .downloads])

        print("\nSummary: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
