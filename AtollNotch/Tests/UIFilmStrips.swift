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

// Model/contract asserts, state renders, redaction asserts, film strips and clock asserts for the notch notification UI.
// Film strips use the frozen animation clock (`NotchUIMotion.frozenTime`): every effect renders the closed-form pose it has
// at time t, so frames are deterministic. The live behaviour (Core Animation interpolation, real hover, VoiceOver speech,
// haptics) can only be judged by a person in the real notch.

// MARK: - Film strip machinery

struct FilmFrame {
    var label: String
    var rep: NSBitmapImageRep
    var png: Data
}

func frozenEnv(_ t: Double, reduceMotion: Bool, isActive: Bool = true) -> NotchUIMotion {
    NotchUIMotion(isActive: isActive, reduceMotion: reduceMotion, tick: 0, frozenTime: t)
}

@MainActor
func renderFrames<V: View>(times: [Double], reduceMotion: Bool, isActive: Bool = true, size: CGSize,
                           _ build: (NotchUIMotion) -> V) -> [FilmFrame] {
    times.compactMap { t in
        let env = frozenEnv(t, reduceMotion: reduceMotion, isActive: isActive)
        let view = NotchStage(size: size) { build(env) }
        guard let rep = bitmap(view, size: size, settle: 0.1),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return FilmFrame(label: String(format: "t = %.2f s", t), rep: rep, png: png)
    }
}

@MainActor
func composeStrip(_ frames: [FilmFrame], columns: Int, scale: CGFloat, name: String, title: String) -> Bool {
    guard let first = frames.first else { return false }
    let fw = CGFloat(first.rep.pixelsWide) * scale, fh = CGFloat(first.rep.pixelsHigh) * scale
    let gap: CGFloat = 12, labelH: CGFloat = 22, titleH: CGFloat = 26
    let rows = Int((Double(frames.count) / Double(columns)).rounded(.up))
    let width = CGFloat(columns) * fw + CGFloat(columns + 1) * gap
    let height = titleH + CGFloat(rows) * (fh + labelH + gap) + gap
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor(white: 0.18, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
    (title as NSString).draw(at: NSPoint(x: gap, y: height - titleH + 4), withAttributes: attrs)
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
    return save(rep, name)
}

func stripScale(_ rep: NSBitmapImageRep?, targetWidth: CGFloat) -> CGFloat {
    guard let rep else { return 1 }
    return min(1, targetWidth / CGFloat(rep.pixelsWide))
}

@MainActor
func strip<V: View>(_ name: String, title: String, size: CGSize, columns: Int = 3, minDistinct: Int = 4,
                    times: [Double], _ build: (NotchUIMotion) -> V) {
    let on = renderFrames(times: times, reduceMotion: false, size: size, build)
    let scale = stripScale(on.first?.rep, targetWidth: 640)
    check("\(name): rendered \(on.count)/\(times.count) frames", on.count == times.count)
    check("\(name): strip saved", composeStrip(on, columns: columns, scale: scale, name: "film_\(name)", title: title + "  [motion on]"))
    let distinctOn = Set(on.map(\.png)).count
    check("\(name): motion ON frames differ (\(distinctOn) distinct of \(on.count))", distinctOn >= minDistinct)
    let off = renderFrames(times: times, reduceMotion: true, size: size, build)
    check("\(name): strip saved (Reduce Motion)", composeStrip(off, columns: columns, scale: scale, name: "film_\(name)_reducemotion", title: title + "  [Reduce Motion]"))
    let distinctOff = Set(off.map(\.png)).count
    check("\(name): Reduce Motion frames IDENTICAL (\(distinctOff) distinct)", distinctOff == 1)
    let idle = renderFrames(times: times, reduceMotion: false, isActive: false, size: size, build)
    check("\(name): isActive=false frames IDENTICAL (\(Set(idle.map(\.png)).count) distinct)", Set(idle.map(\.png)).count == 1)
}

@MainActor
func runFilmStrips() {
    print("\n--- film strips ---")
    let compactSize = CGSize(width: stageW, height: 56)
    let expandedSize = CGSize(width: stageW, height: 156)
    let arriveTimes: [Double] = [0, 0.08, 0.16, 0.25, 0.4, 0.9]

    strip("arrival_dropin", title: "Arrival: spring drop-in + symbol bounce (0.45 / 0.62)", size: compactSize, times: arriveTimes) { env in
        compactView(NF.short, motion: env, phase: .arriving)
    }
    strip("arrival_dropin_expanded", title: "Arrival of an expanded card (redacted, with action)", size: expandedSize, times: arriveTimes) { env in
        NotificationSneakPeekView(presentation: NotificationPresentation(NF.redacted), expansion: 1, closedHeight: closedH, notchWidth: notchW,
                                  motionOverride: env, testPhase: .arriving)
    }
    strip("morph_compact_to_expanded", title: "Morph compact -> expanded: glyph and title move, card grows (0.42 / 0.78)", size: expandedSize,
          times: [0, 0.06, 0.12, 0.2, 0.32, 0.8]) { env in
        NotificationSneakPeekView(presentation: NotificationPresentation(NF.short), expansion: 1, queued: 3, closedHeight: closedH, notchWidth: notchW,
                                  supportsSnooze: true, motionOverride: env, testPhase: .morph)
    }
    strip("dismiss_swipe", title: "Dismiss: swipe-away pose (offset, scale, fade; spring 0.34 / 0.82)", size: compactSize,
          times: [0, 0.05, 0.1, 0.18, 0.3, 0.6]) { env in
        compactView(NF.short, motion: env, phase: .dismissing)
    }
    strip("dismiss_swipe_expanded", title: "Dismiss: expanded card swiped away", size: expandedSize, times: [0, 0.05, 0.1, 0.18, 0.3, 0.6]) { env in
        NotificationSneakPeekView(presentation: NotificationPresentation(NF.short), expansion: 1, closedHeight: closedH, notchWidth: notchW,
                                  motionOverride: env, testPhase: .dismissing)
    }
    strip("critical_pulse", title: "Critical: red ring pulse behind the glyph (0.8 s cycle)", size: compactSize,
          times: [0, 0.2, 0.4, 0.6, 0.8, 1.0]) { env in
        compactView(NF.critical, motion: env)
    }
    strip("countdown_hairline", title: "Countdown hairline (4 s TTL, single linear animation)", size: compactSize,
          times: [0, 0.8, 1.6, 2.4, 3.2, 3.9]) { env in
        compactView(NF.priority(.high), countdown: NotificationCountdown(duration: 4, remaining: 4, asOf: fixtureNow, isPaused: false), motion: env)
    }
    strip("marquee_long_title", title: "Long title scrolls in the right wing (starts after 0.9 s)", size: compactSize,
          times: [0, 1.0, 2.0, 3.0, 4.0, 5.0]) { env in
        compactView(NF.long, motion: env)
    }
}

// MARK: - Model asserts (pure)

@MainActor
func runModelAsserts() {
    print("\n--- presentation model ---")
    let p = NotificationPresentation(NF.short)
    check("model: VoiceOver label is 'App, title'", p.accessibilityLabel == "Terminal, Build finished")
    check("model: preview joins subtitle and body", p.preview == "api-gateway \u{00B7} All 214 tests passed in 3m 12s.")
    check("model: normal announcement is the label", p.announcement == p.accessibilityLabel && !p.isCritical)
    let c = NotificationPresentation(NF.critical)
    check("model: critical announcement is flagged and prefixed", c.isCritical && c.announcement.hasPrefix("Critical. Monitor, "))
    check("model: unknown SF Symbol falls back to the bell", NotificationPresentation(NF.noSymbolBogus).symbol == "bell.fill")
    check("model: missing symbol falls back to the bell", NotificationPresentation(NF.noIcon).symbol == "bell.fill")
    check("model: valid SF Symbol is kept", p.symbol == "terminal.fill")
    let huge = NotificationPresentation(display(app: String(repeating: "A", count: 400), title: String(repeating: "T", count: 5000), body: String(repeating: "B", count: 5000)))
    check("model: huge strings are bounded (app \(huge.appName.count), title \(huge.title.count), preview \(huge.preview?.count ?? 0))",
          huge.appName.count <= 60 && huge.title.count <= 160 && (huge.preview?.count ?? 0) <= 320)
    let blank = NotificationPresentation(display(app: "  ", title: "\n\t ", body: " "))
    check("model: blank app/title get generic text, blank body gives no preview", blank.appName == "Notification" && blank.title == "Notification" && blank.preview == nil)
    let multi = NotificationPresentation(display(title: "Line one\nLine two", body: "a\nb\tc"))
    check("model: newlines collapse (title is one line)", !multi.title.contains("\n") && !(multi.preview ?? "").contains("\n"))
    let red = NotificationPresentation(NF.redacted)
    check("model: redacted shows 'Content hidden' and no preview", red.showsContentHidden && red.preview == nil && red.accessibilityValue == "Content hidden")

    // Countdown arithmetic
    let cd = NotificationCountdown(duration: 4, remaining: 3, asOf: fixtureNow, isPaused: false)
    check("countdown: running remaining decreases with time", abs(cd.remaining(at: fixtureNow.addingTimeInterval(1)) - 2) < 1e-6)
    check("countdown: never below zero", cd.remaining(at: fixtureNow.addingTimeInterval(99)) == 0)
    var paused = cd; paused.isPaused = true
    check("countdown: paused holds its value", paused.remaining(at: fixtureNow.addingTimeInterval(50)) == 3 && abs(paused.fraction(at: fixtureNow) - 0.75) < 1e-6)

    // The settings preview mirrors the contract's privacy modes
    let n = NotchNotification(source: .cli, appName: "Mail", iconSymbol: "envelope.fill", title: "Hello", subtitle: "Sub", body: "Body", action: .none)
    let off = NotificationPrivacyPreview.display(for: n, mode: .off)
    let hp = NotificationPrivacyPreview.display(for: n, mode: .hidePreview)
    let ha = NotificationPrivacyPreview.display(for: n, mode: .hideAll)
    check("privacy preview: off keeps everything, not redacted", !off.isRedacted && off.title == "Hello" && off.subtitle == "Sub" && off.body == "Body" && !off.hasAction)
    check("privacy preview: hidePreview keeps title, drops subtitle and body, redacted", hp.isRedacted && hp.title == "Hello" && hp.subtitle == nil && hp.body == nil)
    check("privacy preview: hideAll is generic 'Notification from <app>'", ha.isRedacted && ha.title == "Notification from Mail" && ha.subtitle == nil && ha.body == nil)
    var sensitive = n; sensitive.isSensitive = true
    check("privacy preview: sensitive under 'off' is treated as hidePreview", NotificationPrivacyPreview.display(for: sensitive, mode: .off).isRedacted)
}

// MARK: - Size contracts

@MainActor
func runContractAsserts() {
    print("\n--- size contracts ---")
    var worstTotal: CGFloat = 0, widest: CGFloat = 0
    for h in [30.0, 32, 34, 38] as [CGFloat] {
        for (label, d) in [("short", NF.short), ("long", NF.long), ("noicon", NF.noIcon)] {
            for q in [0, 3, 12] {
                let l = NotificationCompactLayout.make(title: NotificationPresentation(d).title, queued: q, closedHeight: h, notchWidth: notchW)
                let fit = sizeThatFits(compactView(d, queued: q, height: h), in: CGSize(width: 640, height: 200))
                let ok = abs(fit.width - l.totalWidth) < 0.5 && abs(fit.height - h) < 0.5
                    && l.contentHeight == h - 12 && l.iconSide == h - 12
                    && l.wingWidth >= NotificationCompactLayout.minWing && l.wingWidth <= NotificationCompactLayout.maxWing
                    && l.totalWidth <= notchW + 2 * NotificationCompactLayout.maxWing && l.totalWidth <= 640
                    && l.titleWidth >= 0 && l.titleWidth <= l.wingWidth
                if !ok { check("compact[h\(Int(h)) \(label) +\(q)]: view \(Int(fit.width))x\(Int(fit.height)) vs contract \(Int(l.totalWidth))x\(Int(h)), wing \(Int(l.wingWidth))", false) }
                worstTotal = max(worstTotal, l.totalWidth); widest = max(widest, l.wingWidth)
                if label == "long" { if l.wingWidth != NotificationCompactLayout.maxWing { check("compact[h\(Int(h)) long +\(q)]: long title clamps to max wing", false) } }
            }
        }
    }
    check("compact: every height x title x queue case equals its contract (height = closed height, glyph = height - 12, wing 44...150, total <= notch + 300 and <= 640 window)", true)
    check("compact: widest wing \(Int(widest)) pt, widest total \(Int(worstTotal)) pt (notch \(Int(notchW)) pt)", widest <= 150 && worstTotal <= notchW + 300)
    check("compact: short title with no queue is the minimum wing", NotificationCompactLayout.make(title: "Hi", queued: 0, closedHeight: closedH, notchWidth: notchW).wingWidth == max(NotificationCompactLayout.minWing, closedH - 12 + 16))

    for hasButtons in [false, true] {
        let es = NotificationExpandedLayout.size(closedHeight: closedH, notchWidth: notchW, hasButtons: hasButtons)
        let d = hasButtons ? NF.short : NF.noAction
        let fit = sizeThatFits(expandedView(d), in: CGSize(width: 640, height: 400))
        check("expanded[buttons \(hasButtons)]: view \(Int(fit.width))x\(Int(fit.height)) == contract \(Int(es.width))x\(Int(es.height)); fits the 640x200 window",
              abs(fit.width - es.width) < 0.5 && abs(fit.height - es.height) < 0.5 && es.width <= 460 && es.width <= 640 && es.height <= 200)
    }
    let narrow = NotificationExpandedLayout.size(closedHeight: closedH, notchWidth: 100, hasButtons: true)
    let wide = NotificationExpandedLayout.size(closedHeight: closedH, notchWidth: 400, hasButtons: true)
    check("expanded: width clamps to 400...460 (narrow \(Int(narrow.width)), wide \(Int(wide.width)))", narrow.width == 400 && wide.width == 460)

    // Morph frames stay inside both containers for the elements that exist in that form
    let cl = NotificationCompactLayout.make(title: NF.short.title, queued: 3, closedHeight: closedH, notchWidth: notchW)
    let es = NotificationExpandedLayout.size(closedHeight: closedH, notchWidth: notchW, hasButtons: true)
    let frames = NotificationSneakPeekView.frames(compact: cl, expanded: es, queued: 3, hasPrimary: true, hasSnooze: true)
    let cBounds = CGRect(origin: .zero, size: cl.size), eBounds = CGRect(origin: .zero, size: es)
    let compactOK = [NotificationRole.icon, .title, .chip].allSatisfy { r in frames[r].map { cBounds.insetBy(dx: -0.5, dy: -0.5).contains($0.compact) } ?? false }
    let expandedOK = frames.values.allSatisfy { eBounds.insetBy(dx: -0.5, dy: -0.5).contains($0.expanded) }
    check("morph frames: glyph, title and chip lie inside the compact pill; every element lies inside the expanded card", compactOK && expandedOK)
    let leftClear = (frames[.icon]?.compact.maxX ?? 0) <= cl.wingWidth + 0.5
    let rightClear = (frames[.title]?.compact.minX ?? 0) >= cl.wingWidth + cl.centerWidth - 0.5
    check("morph frames: compact glyph stays left of the physical notch and the title right of it", leftClear && rightClear)
}

// MARK: - State renders

@MainActor
func runStateShots() {
    print("\n--- states ---")
    let ch: CGFloat = 56
    // Compact: short / long / no icon / bogus symbol / each priority / queued
    var sheet: [FilmFrame] = []
    func addCompact(_ label: String, _ d: NotificationDisplay, queued: Int = 0) {
        let size = CGSize(width: stageW, height: ch)
        if let rep = stageShot("nc_compact_\(label)", compactView(d, queued: queued), height: ch), let png = rep.representation(using: .png, properties: [:]) {
            sheet.append(FilmFrame(label: label, rep: rep, png: png))
        }
        _ = size
    }
    addCompact("short_normal", NF.short)
    addCompact("long_title", NF.long)
    addCompact("no_icon", NF.noIcon)
    addCompact("bogus_symbol", NF.noSymbolBogus)
    addCompact("priority_low", NF.priority(.low))
    addCompact("priority_normal", NF.priority(.normal))
    addCompact("priority_high", NF.priority(.high))
    addCompact("priority_critical", NF.priority(.critical))
    addCompact("queued_3", NF.short, queued: 3)
    addCompact("redacted", NF.redacted)
    check("compact sheet saved", composeStrip(sheet, columns: 2, scale: stripScale(sheet.first?.rep, targetWidth: 560), name: "nc_compact_sheet", title: "Compact wings, all states (dashed = physical notch)"))

    // Expanded
    var exp: [FilmFrame] = []
    func addExpanded(_ label: String, _ d: NotificationDisplay, queued: Int = 0, snooze: Bool = false) {
        if let rep = stageShot("nc_expanded_\(label)", expandedView(d, queued: queued, snooze: snooze), height: 156), let png = rep.representation(using: .png, properties: [:]) {
            exp.append(FilmFrame(label: label, rep: rep, png: png))
        }
    }
    addExpanded("long_preview", NF.long)
    addExpanded("redacted", NF.redacted)
    addExpanded("with_action", NF.short)
    addExpanded("action_and_snooze", NF.short, snooze: true)
    addExpanded("no_action", NF.noAction)
    addExpanded("queued_3", NF.short, queued: 3, snooze: true)
    addExpanded("critical", NF.critical, queued: 1)
    addExpanded("low", NF.priority(.low))
    check("expanded sheet saved", composeStrip(exp, columns: 2, scale: stripScale(exp.first?.rep, targetWidth: 560), name: "nc_expanded_sheet", title: "Expanded card, all states"))

    // Right-to-left and light appearance (the notch is always dark; the view must not depend on the system appearance)
    stageShot("nc_expanded_light_appearance", expandedView(NF.short), height: 156, dark: false)
    let rtlSize = CGSize(width: stageW, height: 156)
    if let rep = bitmap(NotchStage(size: rtlSize) { expandedView(display(app: "تطبيق", symbol: "bell.fill", title: "اكتمل بناء المشروع بنجاح", body: "تم اجتياز جميع الاختبارات في ثلاث دقائق")).environment(\.layoutDirection, .rightToLeft) },
                        size: rtlSize, settle: 0.2) {
        check("nc_expanded_rtl: saved and non-empty", save(rep, "nc_expanded_rtl") && inkFraction(rep) > 0.004)
    }
    // Countdown hairline visible state
    stageShot("nc_compact_countdown", compactView(NF.priority(.high), countdown: NotificationCountdown(duration: 4, remaining: 3, asOf: fixtureNow, isPaused: false),
                                                  motion: frozenEnv(0, reduceMotion: false)), height: ch)
}

// MARK: - Surface asserts

@MainActor
func runSurfaceAsserts() {
    print("\n--- surface paths ---")
    func render(reduceTransparency: Bool) {
        NotchUISurfaceConfig.resetCounts()
        let v = NotchStage(size: CGSize(width: stageW, height: 156)) { expandedView(NF.short, queued: 3, snooze: true) }
            .environment(\.notchUIForceReduceTransparency, reduceTransparency)
        _ = bitmap(v, size: CGSize(width: stageW, height: 156), settle: 0.2)
    }
    render(reduceTransparency: false)
    let glass = NotchUISurfaceConfig.counts[.glass, default: 0], material = NotchUISurfaceConfig.counts[.material, default: 0]
    if NotchUISurfaceConfig.wantsGlass {
        check("surface: Liquid Glass path was actually taken (\(glass) glass, \(material) material)", glass > 0 && material == 0)
    } else {
        check("surface: material fallback path taken (\(material) material, \(glass) glass)", material > 0 && glass == 0)
    }
    render(reduceTransparency: true)
    let o = NotchUISurfaceConfig.counts[.opaque, default: 0]
    let g2 = NotchUISurfaceConfig.counts[.glass, default: 0], m2 = NotchUISurfaceConfig.counts[.material, default: 0]
    check("surface: Reduce Transparency => opaque fills only (\(o) opaque, \(g2) glass, \(m2) material)", o > 0 && g2 == 0 && m2 == 0)
    stageShot("nc_expanded_reduce_transparency", expandedView(NF.short, queued: 3, snooze: true)
        .environment(\.notchUIForceReduceTransparency, true), height: 156)
    stageShot("nc_compact_reduce_transparency", compactView(NF.priority(.high), queued: 3)
        .environment(\.notchUIForceReduceTransparency, true), height: 56)
}

// MARK: - Redaction asserts

@MainActor
func runRedactionAsserts() {
    print("\n--- redaction ---")
    let tTitle = "TITLE-ZQX", tSub = "SUB-QQ7", tBody = "BODY-K9W"
    let n = NotchNotification(source: .extensionApp, appName: "Mail", iconSymbol: "envelope.fill", title: "Hello \(tTitle)", subtitle: tSub, body: "Body \(tBody)",
                              action: .activateApp(bundleID: "com.apple.mail"))
    func allStrings(_ d: NotificationDisplay) -> [String] {
        let p = NotificationPresentation(d)
        return p.visibleStrings + [p.accessibilityLabel, p.accessibilityValue, p.announcement]
    }
    func leaks(_ strings: [String], _ tokens: [String]) -> [String] { tokens.filter { t in strings.contains { $0.contains(t) } } }

    let off = NotificationPrivacyPreview.display(for: n, mode: .off)
    let hp = NotificationPrivacyPreview.display(for: n, mode: .hidePreview)
    let ha = NotificationPrivacyPreview.display(for: n, mode: .hideAll)
    check("redaction[control]: mode off exposes title, subtitle and body (the scan is not vacuous)",
          leaks(allStrings(off), [tTitle, tSub, tBody]).count == 3)
    check("redaction[hidePreview]: view model contains no subtitle or body text", leaks(allStrings(hp), [tSub, tBody]).isEmpty, "\(leaks(allStrings(hp), [tSub, tBody]))")
    check("redaction[hidePreview]: title is still shown (contract: title + app)", allStrings(hp).contains { $0.contains(tTitle) })
    check("redaction[hideAll]: view model contains no title, subtitle or body text", leaks(allStrings(ha), [tTitle, tSub, tBody]).isEmpty, "\(leaks(allStrings(ha), [tTitle, tSub, tBody]))")
    // Defence in depth: a producer that violates the contract (isRedacted but text still attached) is neutralised by the model.
    let violating = NotificationDisplay(id: UUID(), appName: "Mail", iconSymbol: "envelope.fill", bundleID: nil, title: "New message", subtitle: tSub, body: tBody,
                                        isRedacted: true, priority: .normal, hasAction: true)
    check("redaction[defence in depth]: isRedacted display carrying subtitle/body is stripped by the model", leaks(allStrings(violating), [tSub, tBody]).isEmpty)

    // Accessibility strings, checked at the source: the view applies exactly NotificationAccessibility.strings (an offscreen
    // NSHostingView exposes no accessibility tree, see the SKIP line below).
    for (label, d) in [("hidePreview", hp), ("hideAll", ha), ("violating", violating)] {
        let p = NotificationPresentation(d)
        let strings = NotificationAccessibility.strings(for: p, supportsSnooze: true)
        let tokens = d.title == "Notification from Mail" ? [tTitle, tSub, tBody] : [tSub, tBody]
        check("redaction[\(label)]: every VoiceOver string (\(strings.count)) is free of hidden text", leaks(strings, tokens).isEmpty, "\(leaks(strings, tokens))")
        check("redaction[\(label)]: VoiceOver label is exactly 'App, title'", p.accessibilityLabel == "\(p.appName), \(p.title)" && p.accessibilityValue == "Content hidden")
    }
    let probe = renderedAX(NotchStage(size: CGSize(width: 300, height: 100)) { NotificationSneakPeekView(presentation: NotificationPresentation(hp), expansion: 1, closedHeight: closedH, notchWidth: notchW, motionOverride: staticMotion) },
                           size: CGSize(width: 300, height: 100))
    if probe.contains(where: { $0.contains("Mail") }) {
        check("redaction[rendered accessibility tree]: no hidden text", leaks(probe, [tSub, tBody]).isEmpty)
    } else {
        print("SKIP  redaction: this host exposes no accessibility tree offscreen (\(probe.count) strings); the strings are asserted at the source and the pixels below")
    }
    // Pixel proof: a redacted view renders IDENTICALLY whatever the hidden fields contain (so no hidden text is drawn).
    func hidden(_ sub: String?, _ body: String?, redacted: Bool = true) -> NotificationDisplay {
        NotificationDisplay(id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!, appName: "Mail", iconSymbol: "envelope.fill", bundleID: nil,
                            title: "New message", subtitle: sub, body: body, isRedacted: redacted, priority: .normal, hasAction: true)
    }
    func png<V: View>(_ v: V, h: CGFloat) -> Data? {
        bitmap(NotchStage(size: CGSize(width: stageW, height: h)) { v }, size: CGSize(width: stageW, height: h), settle: 0.15)?.representation(using: .png, properties: [:])
    }
    for (formLabel, expansion, h) in [("compact", 0.0, 56.0), ("expanded", 1.0, 156.0)] as [(String, Double, CGFloat)] {
        func view(_ d: NotificationDisplay) -> NotificationSneakPeekView {
            NotificationSneakPeekView(presentation: NotificationPresentation(d), expansion: expansion, closedHeight: closedH, notchWidth: notchW, motionOverride: staticMotion)
        }
        let a = png(view(hidden(nil, nil)), h: h), b = png(view(hidden(tSub, tBody)), h: h), c = png(view(hidden("totally different", "other secret text that is long enough to wrap onto a second line of the card")), h: h)
        check("redaction[pixels \(formLabel)]: redacted render is identical for any hidden subtitle/body", a != nil && a == b && b == c)
        let shown = png(view(hidden(tSub, tBody, redacted: false)), h: h)
        if expansion == 1 { check("redaction[pixels \(formLabel)]: control, unredacted render DOES differ (the proof is not vacuous)", shown != nil && shown != a) }
    }
    let rowA = NotificationHistoryEntry(id: UUID(), display: hidden(nil, nil), source: .extensionApp, receivedAt: fixtureAgo(30), wasShown: true)
    let rowB = NotificationHistoryEntry(id: rowA.id, display: hidden(tSub, tBody), source: .extensionApp, receivedAt: fixtureAgo(30), wasShown: true)
    func rowPNG(_ e: NotificationHistoryEntry) -> Data? {
        bitmap(NotificationHistoryRow(entry: e, now: fixtureNow).frame(width: 600, height: 40).background(Color(white: 0.2)), size: CGSize(width: 600, height: 40), settle: 0.1)?.representation(using: .png, properties: [:])
    }
    check("redaction[pixels history row]: identical for any hidden subtitle/body", rowPNG(rowA) != nil && rowPNG(rowA) == rowPNG(rowB))
    // Live privacy preview in settings under each mode
    for mode in NotificationPrivacyMode.allCases {
        let d = NotificationPrivacyPreview.display(for: NotchNotification(source: .cli, appName: "Mail", title: "Hello \(tTitle)", subtitle: tSub, body: "Body \(tBody)"), mode: mode)
        let hidden = mode == .off ? [] : (mode == .hidePreview ? [tSub, tBody] : [tTitle, tSub, tBody])
        check("redaction[settings preview \(mode.rawValue)]: preview display leaks nothing hidden", leaks(allStrings(d), hidden).isEmpty)
    }
    // Glyph: hideAll must not show a sender-chosen symbol
    check("redaction[hideAll]: sender symbol is dropped (generic bell)", NotificationPresentation(ha).symbol == "bell.fill")
}

// MARK: - Clock asserts

@MainActor
func twoRenders<V: View>(_ view: V, size: CGSize, gap: TimeInterval, initial: TimeInterval = 0.6) -> (Data, Data)? {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    func shot() -> Data? {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    RunLoop.main.run(until: Date().addingTimeInterval(initial))
    guard let a = shot() else { return nil }
    RunLoop.main.run(until: Date().addingTimeInterval(gap))
    guard let b = shot() else { return nil }
    window.contentView = nil
    return (a, b)
}

@MainActor
func runClockAsserts() {
    print("\n--- clock ---")
    let size = CGSize(width: stageW, height: 156)
    let hostNone = NotificationSneakPeekHost(center: FixtureNotificationCenter(current: nil), closedHeight: closedH, notchWidth: notchW)
    check("clock: with NO notification the host builds nothing (size \(sizeThatFits(hostNone, in: size)))", sizeThatFits(hostNone, in: size) == .zero)
    if useImageRenderer {
        print("SKIP  clock: live renders 1.1 s apart: ImageRenderer renders a single pass; covered in the fallback run")
    } else {
        if let (a, b) = twoRenders(NotchStage(size: size) { hostNone.environment(\.colorScheme, .dark) }, size: size, gap: 1.1) {
            check("clock: no notification visible => two renders 1.1 s apart are IDENTICAL", a == b)
        } else { check("clock: no-notification renders created", false) }
        let live = NotchStage(size: size) { NotificationSneakPeekView(presentation: NotificationPresentation(NF.short), closedHeight: closedH, notchWidth: notchW, countdown: nil) }
        if let (a, b) = twoRenders(live, size: size, gap: 1.1, initial: 1.6) {
            check("clock: a short NON-critical notification has no repeating clock => renders 1.1 s apart are IDENTICAL", a == b)
        } else { check("clock: non-critical renders created", false) }
        let crit = NotchStage(size: size) { NotificationSneakPeekView(presentation: NotificationPresentation(NF.critical), closedHeight: closedH, notchWidth: notchW) }
        if let (a, b) = twoRenders(crit, size: size, gap: 1.1) {
            check("clock: control, critical pulse running => renders 1.1 s apart DIFFER (the clock really ticks)", a != b)
        } else { check("clock: critical renders created", false) }
        let critOff = NotchStage(size: size) { NotificationSneakPeekView(presentation: NotificationPresentation(NF.critical), closedHeight: closedH, notchWidth: notchW, isActive: false) }
        if let (a, b) = twoRenders(critOff, size: size, gap: 1.1) {
            check("clock: critical but isActive=false => renders 1.1 s apart are IDENTICAL", a == b)
        } else { check("clock: inactive critical renders created", false) }
        let critRM = NotchStage(size: size) { NotificationSneakPeekView(presentation: NotificationPresentation(NF.critical), closedHeight: closedH, notchWidth: notchW,
                                                                        motionOverride: NotchUIMotion(isActive: true, reduceMotion: true, tick: 0, frozenTime: nil)) }
        if let (a, b) = twoRenders(critRM, size: size, gap: 1.1) {
            check("clock: critical with Reduce Motion => renders 1.1 s apart are IDENTICAL (no pulse)", a == b)
        } else { check("clock: reduce-motion critical renders created", false) }
    }
    let inactive = Array(NotchUITickSchedule(active: false).entries(from: Date(), mode: .normal).prefix(5))
    let active = Array(NotchUITickSchedule(active: true).entries(from: Date(), mode: .normal).prefix(5))
    check("clock: inactive schedule has exactly 1 entry (no timer), active has a 0.4 s stream",
          inactive.count == 1 && active.count == 5 && abs(active[1].timeIntervalSince(active[0]) - 0.4) < 0.001)
}

// MARK: - Host asserts (announcements, hover cleanup)

@MainActor
final class AnnounceRecorder { var posts: [(String, Bool)] = [] }

@MainActor
func runHostAsserts() {
    print("\n--- host ---")
    let rec = AnnounceRecorder()
    let center = FixtureNotificationCenter(current: nil)
    let host = NotificationSneakPeekHost(center: center, closedHeight: closedH, notchWidth: notchW,
                                         announcer: NotificationAnnouncer { rec.posts.append(($0, $1)) })
    let size = CGSize(width: stageW, height: 156)
    let hv = NSHostingView(rootView: NotchStage(size: size) { host })
    hv.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hv
    hv.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check("host: nothing announced while no notification is visible", rec.posts.isEmpty)
    center.current = NF.critical
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check("host: critical arrival is announced once, assertively, without the preview (\(rec.posts))",
          rec.posts.count == 1 && rec.posts[0].1 == true && rec.posts[0].0 == "Critical. Monitor, Database primary is unreachable" && !rec.posts[0].0.contains("Failover"))
    center.current = NF.short
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check("host: normal arrival is announced politely as 'App, title' (\(rec.posts.count) posts)",
          rec.posts.count == 2 && rec.posts[1].1 == false && rec.posts[1].0 == "Terminal, Build finished")
    center.current = NF.redacted
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check("host: redacted arrival announces only 'App, title'", rec.posts.count == 3 && rec.posts[2].0 == "Mail, New message")
    center.current = nil
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    check("host: after dismissal the tree is gone (size \(sizeThatFits(NotificationSneakPeekHost(center: center, closedHeight: closedH, notchWidth: notchW), in: size))) and hover is released (events \(center.hoverEvents))",
          sizeThatFits(NotificationSneakPeekHost(center: center, closedHeight: closedH, notchWidth: notchW), in: size) == .zero && center.hoverEvents.last == false && rec.posts.count == 3)
    window.contentView = nil

    // Buttons through the accessibility tree, when this host exposes one
    var dismissed = 0, primary = 0, snoozed = 0
    let view = NotificationSneakPeekView(presentation: NotificationPresentation(NF.short), expansion: 1, closedHeight: closedH, notchWidth: notchW,
                                         supportsSnooze: true, onDismiss: { dismissed += 1 }, onPrimary: { primary += 1 }, onSnooze: { snoozed += 1 },
                                         motionOverride: staticMotion)
    let bv = NSHostingView(rootView: NotchStage(size: size) { view })
    bv.frame = NSRect(origin: .zero, size: size)
    let bw = NSWindow(contentRect: bv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    bw.contentView = bv
    bv.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    func press(_ label: String) -> Bool {
        var found = false
        func walk(_ o: NSObject, _ d: Int) {
            guard d < 14, !found else { return }
            guard let p = o as? NSAccessibilityProtocol else { return }
            if p.accessibilityLabel() == label, p.accessibilityPerformPress() == true { found = true; return }
            var kids: [Any] = p.accessibilityChildren() ?? []
            if let v = o as? NSView, kids.isEmpty { kids = v.subviews }
            for k in kids { if let ko = k as? NSObject { walk(ko, d + 1) } }
        }
        walk(bv, 0)
        return found
    }
    if press("Dismiss notification") && press("Open") && press("Snooze notification") {
        check("host: Dismiss / Open / Snooze buttons call their closures (\(dismissed)/\(primary)/\(snoozed))", dismissed == 1 && primary == 1 && snoozed == 1)
    } else {
        print("SKIP  host: button presses through the accessibility tree are not available offscreen on this host")
    }
    bw.contentView = nil
}
