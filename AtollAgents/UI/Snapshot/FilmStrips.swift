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

// Film strips (deterministic animation frames), surface/motion asserts, closed-indicator states and the render-cost
// measurement. Frames use the frozen animation clock of AgentsMotionEnvironment (`frozenTime`), so every effect renders
// the closed-form pose it has at time t; the live behaviour (Core Animation interpolation between 0.4 s ticks) can only
// be judged by a person in the real notch.

let filmTimes: [Double] = [0, 0.25, 0.5, 0.75, 1.0, 1.5]

func frozenEnv(_ t: Double, reduceMotion: Bool, isActive: Bool = true) -> AgentsMotionEnvironment {
    AgentsMotionEnvironment(isActive: isActive, reduceMotion: reduceMotion, tick: 0, frozenTime: t, frozenNow: now)
}

struct NamespaceHolder<Content: View>: View {
    @Namespace private var ns
    let content: (Namespace.ID) -> Content
    var body: some View { content(ns) }
}

struct FilmFrame {
    var label: String
    var rep: NSBitmapImageRep
    var png: Data
}

@MainActor
func renderFrames<V: View>(times: [Double], reduceMotion: Bool, isActive: Bool = true, size: CGSize,
                           _ build: (AgentsMotionEnvironment) -> V) -> [FilmFrame] {
    times.compactMap { t in
        let env = frozenEnv(t, reduceMotion: reduceMotion, isActive: isActive)
        let view = build(env)
            .environment(\.agentsMotion, env)
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
            .background(Color.black)
        guard let rep = bitmap(view, size: size, settle: 0.12),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return FilmFrame(label: String(format: "t = %.2f s", t), rep: rep, png: png)
    }
}

/// Lays frames out in a grid with labels and writes one PNG.
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
    NSColor(white: 0.22, alpha: 1).setFill()
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

@MainActor
func strip<V: View>(_ name: String, title: String, size: CGSize, columns: Int = 6, scale: CGFloat = 0.5,
                    minDistinct: Int = 4, times: [Double] = filmTimes, _ build: (AgentsMotionEnvironment) -> V) {
    // Motion on
    let on = renderFrames(times: times, reduceMotion: false, size: size, build)
    check("\(name): rendered \(on.count)/\(times.count) frames", on.count == times.count)
    check("\(name): strip saved", composeStrip(on, columns: columns, scale: scale, name: "film_\(name)", title: title + "  [motion on]"))
    let distinctOn = Set(on.map(\.png)).count
    check("\(name): motion ON frames differ (\(distinctOn) distinct of \(on.count))", distinctOn >= minDistinct)
    // Reduce Motion
    let off = renderFrames(times: times, reduceMotion: true, size: size, build)
    check("\(name): strip saved (Reduce Motion)", composeStrip(off, columns: columns, scale: scale, name: "film_\(name)_reducemotion", title: title + "  [Reduce Motion]"))
    let distinctOff = Set(off.map(\.png)).count
    check("\(name): Reduce Motion frames IDENTICAL (\(distinctOff) distinct)", distinctOff == 1)
    // isActive = false
    let idle = renderFrames(times: times, reduceMotion: false, isActive: false, size: size, build)
    check("\(name): isActive=false frames IDENTICAL (\(Set(idle.map(\.png)).count) distinct)", Set(idle.map(\.png)).count == 1)
}

// MARK: - Fixtures for strips

@MainActor
func makeApprovalFixture() -> (PendingApproval, AgentSession) {
    let need = session(.claudeCode, "s-need", "website", status: .needsPermission, title: "Fix the checkout flow", since: 31)
    let ap = approval(need, summary: "rm -rf node_modules && npm ci",
                      detail: "rm -rf node_modules && npm ci\n# cwd: ~/Desktop/github/website",
                      suggestions: [PermissionSuggestion(id: 0, label: "Always allow Bash(npm ci:*)")])
    return (ap, need)
}

@MainActor
func runFilmStrips() {
    // 1. breathing orb
    strip("breathing_orb", title: "Running orb: breathing 0.92...1.08 scale, 0.65...1.0 opacity, 2.4 s cycle",
          size: CGSize(width: 140, height: 110)) { _ in AgentsOrb(status: .running, size: 14).scaleEffect(5) }
    // 2. attention pulse
    strip("attention_pulse", title: "Needs-you orb: expanding ring, 0.8 s cycle",
          size: CGSize(width: 140, height: 110)) { _ in AgentsOrb(status: .needsPermission, size: 14).scaleEffect(4) }
    // 3. row expand morph (real notch view, collapsed -> expanded)
    let full = session(.claudeCode, "s-full", "Toplet", status: .running, title: "Ship the hooks installer",
                       tool: bash("swift build -c release", 23), since: 400, tasks: fixtureTasks(), subs: fixtureSubagents(),
                       model: "claude-opus-4-1", mode: "acceptEdits", lastText: "Wiring the uninstall path so only marked entries are removed.")
    let cRow = AgentCenter.preview(sessions: [full], hooks: .installed(claude: true, codex: false))
    strip("row_expand_morph", title: "Session row: collapsed -> expanded (spring reveal, 0.38 s)",
          size: CGSize(width: contentWidth, height: 360), columns: 3, scale: 0.55, minDistinct: 4,
          times: [0, 0.08, 0.16, 0.25, 0.4, 0.8]) { env in
        NotchAgentsView(center: cRow, motionOverride: env, uiSeed: { $0.expandedSessions = [full.id]; $0.expandedSubagents = [full.id] })
    }
    // 4. approval card drop-in
    let (ap, need) = makeApprovalFixture()
    strip("approval_drop_in", title: "Approval card: drop-in with overshoot (spring 0.45 / 0.62)",
          size: CGSize(width: contentWidth, height: 150), columns: 3, scale: 0.55, minDistinct: 4,
          times: [0, 0.1, 0.2, 0.3, 0.45, 0.9]) { env in
        NamespaceHolder { ns in
            AgentsGlassGroup(spacing: 4) {
                ApprovalCardView(approval: ap, session: need, now: now, glassNamespace: ns, isExpanded: false, alwaysAllow: nil,
                                 onToggleDetail: {}, onDecide: { _ in }, onRequestAlways: { _ in }, onCancelAlways: {})
                    .modifier(DropPose(progress: env.animates ? AgentsPose.spring(env.frozenTime ?? 0, AgentsMotion.cardDropSpring) : 1))
            }
            .padding(.horizontal, 12).padding(.top, 8)
        }
    }
    // 5. check-off
    strip("check_off", title: "Task check-off: drawn checkmark + fill (spring 0.38 / 0.6)",
          size: CGSize(width: 140, height: 110), minDistinct: 4,
          times: [0, 0.08, 0.16, 0.25, 0.4, 0.8]) { _ in AgentsCheckbox(isDone: true, size: 16).scaleEffect(4.5) }
    // 6. status change running -> done / failed
    strip("status_morph_done", title: "Status orb: running -> done (symbol morph, spring 0.45)",
          size: CGSize(width: 140, height: 110), minDistinct: 4,
          times: [0, 0.08, 0.16, 0.25, 0.4, 0.8]) { _ in AgentsOrb(status: .done, finished: true, morphFrom: .running, size: 14).scaleEffect(5) }
    strip("status_morph_failed", title: "Status orb: running -> failed",
          size: CGSize(width: 140, height: 110), minDistinct: 4,
          times: [0, 0.08, 0.16, 0.25, 0.4, 0.8]) { _ in AgentsOrb(status: .failed, morphFrom: .running, size: 14).scaleEffect(5) }
    // 7. board drag highlight
    let boardD = fixtureBoard()
    let cDrag = AgentCenter.preview(board: boardD, hooks: .installed(claude: true, codex: false))
    strip("board_drag_highlight", title: "Board: drop-target highlight on section 'Ideas' (spring 0.3 / 0.6)",
          size: CGSize(width: contentWidth, height: 470), columns: 3, scale: 0.5, minDistinct: 4,
          times: [0, 0.06, 0.12, 0.2, 0.35, 0.8]) { env in
        NotchAgentsView(center: cDrag, motionOverride: env, uiSeed: { $0.dropTarget = .section(boardD[1].id); $0.draggingTask = boardD[0].tasks[1].id })
    }
}

// MARK: - Closed indicator

@MainActor
func closedSummary(_ specs: [(AgentKind, AgentsClosedState, Int)]) -> AgentsClosedSummary {
    AgentsClosedSummary(kinds: specs.map { AgentsClosedKind(kind: $0.0, state: $0.1, count: $0.2) })
}

@MainActor
func runClosedIndicator() {
    let height: CGFloat = 22                       // effectiveClosedNotchHeight (34) - 12
    let cases: [(String, AgentsClosedSummary)] = [
        ("running", closedSummary([(.claudeCode, .running, 1)])),
        ("needs you x2", closedSummary([(.claudeCode, .attention, 2)])),
        ("finished", closedSummary([(.codex, .finished, 1)])),
        ("failed", closedSummary([(.claudeCode, .failed, 1)])),
        ("two agents", closedSummary([(.claudeCode, .running, 3), (.codex, .attention, 1)])),
        ("none", AgentsClosedSummary()),
    ]
    // Size contract
    for (label, summary) in cases {
        let w = AgentsClosedIndicator.width(for: summary, height: height)
        let fit = sizeThatFits(AgentsClosedIndicator(summary: summary, height: height), in: CGSize(width: 200, height: 60))
        if summary.isEmpty {
            check("closed[\(label)]: ZERO width (contract \(w), view \(Int(fit.width))x\(Int(fit.height)))", w == 0 && fit.width == 0 && fit.height == 0)
        } else {
            check("closed[\(label)]: width \(Int(fit.width)) == contract \(Int(w)), height \(Int(fit.height)) == \(Int(height))",
                  abs(fit.width - w) < 0.5 && abs(fit.height - height) < 0.5 && w >= 18 && w <= 64)
        }
    }
    check("closed: summary logic (attention > failed > finished > running per kind)", {
        var a = session(.claudeCode, "c1", "p", status: .running)
        a.isLive = true
        var b = session(.claudeCode, "c2", "p", status: .needsPermission)
        b.isLive = true
        let s = AgentsClosedSummary.make(sessions: [a, b], pending: [])
        return s.kinds.count == 1 && s.kinds[0].state == .attention && s.kinds[0].count == 1
    }())
    check("closed: idle-only sessions produce no indicator", AgentsClosedSummary.make(sessions: [session(.codex, "i1", "p", status: .idle)], pending: []).isEmpty)

    // States on a black notch-height strip, dark + light, as a film strip of the animation clock for each state
    for dark in [true, false] {
        let suffix = dark ? "dark" : "light"
        var frames: [FilmFrame] = []
        for (label, summary) in cases {
            let size = CGSize(width: 150, height: 34)
            let v = ClosedStripBackdrop(width: size.width, height: size.height) {
                AgentsClosedIndicator(summary: summary, height: height, motionOverride: frozenEnv(0.6, reduceMotion: false))
            }
            .environment(\.colorScheme, dark ? .dark : .light)
            if let rep = bitmap(v, size: size, dark: dark, settle: 0.12), let png = rep.representation(using: .png, properties: [:]) {
                frames.append(FilmFrame(label: label, rep: rep, png: png))
                if !summary.isEmpty {
                    check("closed[\(label)] \(suffix): non-empty render", inkFraction(rep, threshold: 0.05) > 0.003)
                }
            }
        }
        check("closed states \(suffix): strip saved", composeStrip(frames, columns: 3, scale: 1.0, name: "film_closed_states_\(suffix)", title: "Closed notch indicator, \(suffix) appearance (h=\(Int(height)) pt wing)"))
    }
    let anim = [closedSummary([(.claudeCode, .running, 1)])]
    func closedStrip(_ name: String, title: String, summary: AgentsClosedSummary, morphFrom: AgentsClosedState? = nil, times: [Double] = filmTimes) {
        let size = CGSize(width: 150, height: 34)
        func frames(rm: Bool, active: Bool = true) -> [FilmFrame] {
            times.compactMap { t in
                let env = frozenEnv(t, reduceMotion: rm, isActive: active)
                let v = ClosedStripBackdrop(width: size.width, height: size.height, notch: 0) {
                    AgentsClosedIndicator(summary: summary, height: height, isActive: active, motionOverride: env, morphFrom: morphFrom)
                }
                guard let rep = bitmap(v.scaleEffect(2.4).frame(width: size.width, height: size.height * 2.4), size: CGSize(width: size.width, height: size.height * 2.4), settle: 0.1),
                      let png = rep.representation(using: .png, properties: [:]) else { return nil }
                return FilmFrame(label: String(format: "t = %.2f s", t), rep: rep, png: png)
            }
        }
        let on = frames(rm: false)
        check("\(name): strip saved", composeStrip(on, columns: 3, scale: 0.8, name: "film_\(name)", title: title + " [motion on]"))
        check("\(name): motion ON frames differ (\(Set(on.map(\.png)).count) distinct)", Set(on.map(\.png)).count >= 4)
        let off = frames(rm: true)
        check("\(name): strip saved (Reduce Motion)", composeStrip(off, columns: 3, scale: 0.8, name: "film_\(name)_reducemotion", title: title + " [Reduce Motion]"))
        check("\(name): Reduce Motion frames IDENTICAL", Set(off.map(\.png)).count == 1)
        check("\(name): isActive=false frames IDENTICAL", Set(frames(rm: false, active: false).map(\.png)).count == 1)
    }
    closedStrip("closed_running_breathing", title: "Closed notch: running glyph breathing", summary: anim[0] == anim[0] ? anim[0] : anim[0])
    closedStrip("closed_attention_pulse", title: "Closed notch: needs permission (ring + count badge)", summary: closedSummary([(.claudeCode, .attention, 2)]))
    closedStrip("closed_finished_morph", title: "Closed notch: orb -> green check (spring morph)", summary: closedSummary([(.codex, .finished, 1)]),
                morphFrom: .running, times: [0, 0.08, 0.16, 0.25, 0.4, 0.8])
}

struct ClosedStripBackdrop<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    var notch: CGFloat = 60
    let content: Content
    init(width: CGFloat, height: CGFloat, notch: CGFloat = 60, @ViewBuilder content: () -> Content) { self.width = width; self.height = height; self.notch = notch; self.content = content() }
    var body: some View {
        // A black closed-notch strip: centre = the physical notch, indicator in the trailing wing like other live activities.
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Rectangle().fill(Color.black).frame(width: notch, height: height)
            content.padding(.leading, 6).padding(.trailing, 8)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height)
        .background(Color.black)
    }
}

// MARK: - Surface, live-clock and performance asserts

@MainActor
func runSurfaceAsserts() {
    let (ap, need) = makeApprovalFixture()
    let c = AgentCenter.preview(sessions: [need], pending: [ap], hooks: .installed(claude: true, codex: false))
    func render(reduceTransparency: Bool) {
        AgentsSurfaceConfig.resetCounts()
        let v = NotchFrame(height: 208) { NotchAgentsView(center: c) }
            .environment(\.agentsForceReduceTransparency, reduceTransparency)
        _ = bitmap(v, size: CGSize(width: notchWidth, height: 252), settle: 0.2)
    }
    render(reduceTransparency: false)
    let glass = AgentsSurfaceConfig.counts[.glass, default: 0], material = AgentsSurfaceConfig.counts[.material, default: 0]
    if AgentsSurfaceConfig.wantsGlass {
        check("surface: Liquid Glass path was actually taken (\(glass) glass, \(material) material)", glass > 0 && material == 0)
    } else {
        check("surface: material fallback path taken (\(material) material, \(glass) glass)", material > 0 && glass == 0)
    }
    render(reduceTransparency: true)
    let o = AgentsSurfaceConfig.counts[.opaque, default: 0]
    let g2 = AgentsSurfaceConfig.counts[.glass, default: 0], m2 = AgentsSurfaceConfig.counts[.material, default: 0]
    check("surface: Reduce Transparency => opaque fills only (\(o) opaque, \(g2) glass, \(m2) material)", o > 0 && g2 == 0 && m2 == 0)
    // Opaque pixel proof: with Reduce Transparency the approval card background is Color(white: 0.14), not a blur.
    if let rep = bitmap(NotchFrame(height: 208) { NotchAgentsView(center: c, motionOverride: frozenEnv(0, reduceMotion: true)) }
        .environment(\.agentsForceReduceTransparency, true), size: CGSize(width: notchWidth, height: 252), settle: 0.2) {
        _ = save(rep, "ui_reduce_transparency_notch")
        check("surface: Reduce Transparency render saved + non-empty", inkFraction(rep) > 0.01)
    }
}

@MainActor
func twoRenders<V: View>(_ view: V, size: CGSize, gap: TimeInterval) -> (Data, Data)? {
    if useImageRenderer {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let a = renderer.cgImage else { return nil }
        RunLoop.main.run(until: Date().addingTimeInterval(gap))
        guard let b = renderer.cgImage else { return nil }
        let pa = NSBitmapImageRep(cgImage: a).representation(using: .png, properties: [:])
        let pb = NSBitmapImageRep(cgImage: b).representation(using: .png, properties: [:])
        guard let pa, let pb else { return nil }
        return (pa, pb)
    }
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
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let a = shot() else { return nil }
    RunLoop.main.run(until: Date().addingTimeInterval(gap))
    guard let b = shot() else { return nil }
    window.contentView = nil
    return (a, b)
}

@MainActor
func runClockAsserts() {
    let sessions = [session(.claudeCode, "k1", "Toplet", status: .running, tool: bash("npm test", 5), since: 30),
                    session(.codex, "k2", "api", status: .needsPermission, since: 12)]
    let c = AgentCenter.preview(sessions: sessions, hooks: .installed(claude: true, codex: true))
    let size = CGSize(width: contentWidth, height: 200)
    if let (a, b) = twoRenders(NotchAgentsView(center: c, isActive: false).environment(\.colorScheme, .dark).background(Color.black), size: size, gap: 1.1) {
        check("clock: isActive=false => two renders 1.1 s apart are IDENTICAL (nothing runs)", a == b)
    } else { check("clock: isActive=false renders created", false) }
    if useImageRenderer {
        print("SKIP  clock: live control (isActive=true changes after 1.1 s): ImageRenderer renders a single pass; covered in the fallback run")
    } else if let (a, b) = twoRenders(NotchAgentsView(center: c, isActive: true).environment(\.colorScheme, .dark).background(Color.black), size: size, gap: 1.1) {
        check("clock: control, isActive=true => renders 1.1 s apart DIFFER (the clock really ticks)", a != b)
    } else { check("clock: control renders created", false) }
    // Static check of the schedule itself: inactive yields exactly one entry, active yields a stream.
    let inactive = Array(AgentsTickSchedule(active: false).entries(from: Date(), mode: .normal).prefix(5))
    let active = Array(AgentsTickSchedule(active: true).entries(from: Date(), mode: .normal).prefix(5))
    check("clock: inactive schedule has exactly 1 entry (no timer), active has a 0.4 s stream",
          inactive.count == 1 && active.count == 5 && abs(active[1].timeIntervalSince(active[0]) - 0.4) < 0.001)
}

@MainActor
func runPerf() {
    let many = mixedSessions(30)
    let ap = many.filter { $0.status == .needsPermission && $0.isLive }.prefix(2).map { approval($0, summary: "npm run build") }
    let c = AgentCenter.preview(sessions: many, pending: Array(ap), board: fixtureBoard(), hooks: .installed(claude: true, codex: true))

    /// Full frame cost = SwiftUI update + layout + software rasterisation of the frame (an upper bound: the live notch
    /// is composited on the GPU).
    func rasterCost(_ label: String, height: CGFloat, frames n: Int, thresholdMs: Double) {
        var times: [Double] = []
        for i in 0..<n {
            let env = frozenEnv(Double(i) * 0.4, reduceMotion: false)
            let v = NotchFrame(height: height) { NotchAgentsView(center: c, motionOverride: env) }
            let t0 = Date()
            _ = bitmap(v, size: CGSize(width: notchWidth, height: AgentsLayout.headerRowHeight + height + 12), settle: 0)
            times.append(Date().timeIntervalSince(t0) * 1000)
        }
        let sorted = times.dropFirst().sorted()
        let avg = sorted.reduce(0, +) / Double(max(1, sorted.count))
        print(String(format: "PERF  %@: avg %.1f ms, worst %.1f ms per frame (update+layout+raster, %d frames, 30 sessions, motion on)", label, avg, sorted.last ?? 0, sorted.count))
        check("perf: \(label) avg \(String(format: "%.0f", avg)) ms < \(Int(thresholdMs)) ms", avg < thresholdMs)
    }

    /// Per-tick update cost = what the shared 0.4 s clock actually costs the app: new environment -> body updates ->
    /// layout, on one persistent hosting view (no rasterisation).
    func tickCost(_ label: String, height: CGFloat, frames n: Int, thresholdMs: Double) {
        let size = CGSize(width: contentWidth, height: height)
        func view(_ i: Int) -> some View {
            NotchAgentsView(center: c, motionOverride: frozenEnv(Double(i) * 0.4, reduceMotion: false))
                .environment(\.colorScheme, .dark)
                .frame(width: size.width, height: size.height)
        }
        let host = NSHostingView(rootView: view(0))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var times: [Double] = []
        for i in 1...n {
            let t0 = Date()
            host.rootView = view(i)
            host.layoutSubtreeIfNeeded()
            times.append(Date().timeIntervalSince(t0) * 1000)
        }
        window.contentView = nil
        let avg = times.reduce(0, +) / Double(times.count)
        print(String(format: "PERF  %@: avg %.1f ms, worst %.1f ms per clock tick (update+layout only, %d ticks)", label, avg, times.max() ?? 0, n))
        check("perf: \(label) tick avg \(String(format: "%.0f", avg)) ms < \(Int(thresholdMs)) ms (0.4 s budget)", avg < thresholdMs)
    }

    rasterCost("viewport 208 pt, full frame", height: 208, frames: 13, thresholdMs: 250)
    tickCost("viewport 208 pt, visible rows only", height: 208, frames: 20, thresholdMs: 40)
    tickCost("2400 pt, all 30 rows realised (worst case)", height: 2400, frames: 8, thresholdMs: 200)
}

@MainActor
func runExtraSuites() {
    print("\n--- surface / motion / closed indicator ---")
    runSurfaceAsserts()
    runFilmStrips()
    runClosedIndicator()
    runClockAsserts()
    runPerf()
}
