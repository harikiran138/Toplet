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

// Offscreen snapshot harness for the Agents UI. Renders NotchAgentsView and AgentsSettingsSection in fixture states to
// PNG files (NSHostingView + bitmapImageRepForCachingDisplay: no screen-capture permission) and asserts invariants.
// Build and run through AtollAgents/Tests/run_ui.sh.

// MARK: - Assertions

@MainActor var failures = 0
@MainActor var passes = 0

@MainActor func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passes += 1; print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)  \(detail)") }
}

// MARK: - Fixtures

let now = Date()
func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

func session(_ kind: AgentKind = .claudeCode, _ id: String, _ project: String, cwd: String? = nil,
             status: SessionStatus, live: Bool = true, title: String? = nil, prompt: String? = nil,
             tool: ToolActivity? = nil, since: TimeInterval = 90, tasks: [AgentTask] = [], subs: [Subagent] = [],
             model: String? = nil, mode: String? = nil, lastText: String? = nil, jump: Bool = true) -> AgentSession {
    let model = model ?? (kind == .claudeCode ? "claude-sonnet-4-6" : "gpt-5-codex")
    var s = AgentSession(key: SessionKey(kind: kind, id: id), cwd: cwd ?? "\(NSHomeDirectory())/Desktop/github/\(project)",
                         projectName: project, status: status, now: ago(since))
    s.title = title; s.lastPrompt = prompt; s.currentTool = tool; s.tasks = tasks; s.subagents = subs
    s.model = model; s.permissionMode = mode; s.lastAssistantText = lastText
    s.isLive = live; s.provenance = live ? .hook : .processScan
    s.statusSince = ago(since); s.lastEventAt = ago(since)
    s.surface = .terminal
    if jump { s.jump = .terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys001") }
    return s
}

func bash(_ summary: String, _ s: TimeInterval = 14) -> ToolActivity { ToolActivity(name: "Bash", summary: summary, startedAt: ago(s)) }

func approval(_ s: AgentSession, tool: String = "Bash", summary: String, detail: String? = nil,
              suggestions: [PermissionSuggestion] = [], expiresIn: TimeInterval = 74, total: TimeInterval = 90, subagent: Bool = false) -> PendingApproval {
    PendingApproval(sessionKey: s.key, agentID: subagent ? "agent-1" : nil, tool: tool, summary: summary, detail: detail,
                    suggestions: suggestions, createdAt: now.addingTimeInterval(expiresIn - total), expiresAt: now.addingTimeInterval(expiresIn))
}

func fixtureTasks() -> [AgentTask] {
    [AgentTask(id: "1", title: "Read the existing hook installer", status: .completed, order: 0),
     AgentTask(id: "2", title: "Add backup + marker", status: .completed, order: 1),
     AgentTask(id: "3", title: "Write the uninstall path", status: .inProgress, activeForm: "Writing the uninstall path", order: 2),
     AgentTask(id: "4", title: "Cover parse failures with tests", status: .pending, order: 3),
     AgentTask(id: "5", title: "Update the changelog", status: .pending, order: 4),
     AgentTask(id: "6", title: "Try the legacy format", status: .cancelled, order: 5)]
}

func fixtureSubagents() -> [Subagent] {
    [Subagent(id: "a", type: "Explore", status: .running, startedAt: ago(48), currentTool: ToolActivity(name: "Grep", summary: "settings.json hooks", startedAt: ago(3))),
     Subagent(id: "b", type: "code-reviewer", status: .done, startedAt: ago(300), lastText: "No blocking issues found in the diff."),
     Subagent(id: "c", type: "test-runner", status: .failed, startedAt: ago(200), lastText: "2 tests failed: HookInstallerTests")]
}

func fixtureBoard() -> [BoardSection] {
    var t1 = BoardTask(title: "Fix flaky timer test", notes: "Only on CI; see run 4412")
    t1.agent = .claudeCode; t1.linkedSessionID = "claude:s-run"
    return [
        BoardSection(title: "Today", tasks: [
            t1,
            BoardTask(title: "Review the hooks PR"),
            BoardTask(title: "Write release notes", isDone: true)]),
        BoardSection(title: "Ideas", tasks: [
            BoardTask(title: "Notch approvals: add a haptic tick", notes: "Maybe behind a setting"),
            BoardTask(title: "Show usage per session", agent: .codex)]),
        BoardSection(title: "Later", tasks: [], isCollapsed: false),
    ]
}

func installedHooks() -> HooksState { .installed(claude: true, codex: true) }

func mixedSessions(_ n: Int) -> [AgentSession] {
    let projects = ["Toplet", "website", "api-gateway", "ios-app", "docs", "infra", "ml-experiments", "dotfiles", "billing", "design-system", "cli-tools", "payments"]
    var out: [AgentSession] = []
    for i in 0..<n {
        let p = projects[i % projects.count] + (i >= projects.count ? "-\(i / projects.count + 1)" : "")
        let kind: AgentKind = i % 3 == 2 ? .codex : .claudeCode
        switch i % 6 {
        case 0: out.append(session(kind, "s\(i)", p, status: .needsPermission, title: "Refactor the settings window", since: 20 + TimeInterval(i), jump: true))
        case 1: out.append(session(kind, "s\(i)", p, status: .running, title: "Add dark mode to the dashboard", tool: bash("npm test -- --watch=false", 12 + TimeInterval(i)),
                                   tasks: fixtureTasks(), subs: Array(fixtureSubagents().prefix(1))))
        case 2: out.append(session(kind, "s\(i)", p, status: .running, prompt: "Why does the build fail on CI?", since: 200))
        case 3: out.append(session(kind, "s\(i)", p, status: .idle, live: i % 2 == 1, prompt: "Summarise yesterday's changes", since: 600 + TimeInterval(i * 30)))
        case 4: out.append(session(kind, "s\(i)", p, status: .failed, title: "Migrate to the new API", since: 1500, lastText: "Rate limit reached."))
        default: out.append(session(kind, "s\(i)", p, status: .done, live: false, prompt: "Old session", since: 7200))
        }
    }
    AgentsUnseenFixture.ids = Set(out.filter { $0.status == .idle && $0.isLive }.map(\.id))       // finished, not yet seen
    return out
}

// MARK: - Rendering

let notchWidth: CGFloat = 640
let contentWidth = AgentsLayout.contentWidth                 // 612
let sidePad = (notchWidth - contentWidth) / 2                // 14

struct FakeTabRow: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(["house.fill", "tray.fill", "timer", "chart.bar.fill", "terminal.fill", "bolt.fill"], id: \.self) { n in
                Image(systemName: n).font(.system(size: 13)).foregroundStyle(n == "bolt.fill" ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 30, height: 26)
                    .background(n == "bolt.fill" ? Color.white.opacity(0.16) : .clear, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, minHeight: AgentsLayout.headerRowHeight, maxHeight: AgentsLayout.headerRowHeight)
    }
}

/// The notch as the host builds it: black, bottom corners rounded, a tab row, the section below it.
struct NotchFrame<Content: View>: View {
    let height: CGFloat
    let content: Content
    init(height: CGFloat, @ViewBuilder content: () -> Content) { self.height = height; self.content = content() }
    var body: some View {
        VStack(spacing: 0) {
            FakeTabRow()
            content.frame(width: contentWidth, height: height)
            Spacer(minLength: 0).frame(height: 12)
        }
        .padding(.horizontal, sidePad)
        .frame(width: notchWidth, height: AgentsLayout.headerRowHeight + height + 12, alignment: .top)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous))
        .background(Color(white: 0.30))        // desktop behind the notch
    }
}

/// Liquid Glass cannot be captured through NSView.cacheDisplay (the whole hosting view comes back blank), so the
/// glass path is rasterised with ImageRenderer (a static approximation of the glass; the live blend over real
/// content cannot be proven offscreen). Everything else uses NSHostingView + cacheDisplay.
@MainActor var useImageRenderer = false

/// ImageRenderer only produces glass after one real NSHostingView with a glass element has lived in a window.
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
@MainActor var glassWarmWindow: NSWindow?

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

@MainActor var outDir = "/tmp/atoll-agents-ui"

@MainActor
func save(_ rep: NSBitmapImageRep, _ name: String) -> Bool {
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name + ".png")
    do { try data.write(to: url); return true } catch { return false }
}

/// Fraction of pixels (inner region, below the top 12%) that differ noticeably from the background sampled at the
/// bottom-centre padding. A blank render has ~0.
func inkFraction(_ rep: NSBitmapImageRep, threshold: CGFloat = 0.12) -> Double {
    guard let base = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 3)?.usingColorSpace(.deviceRGB) else { return 0 }
    var diff = 0, total = 0
    let x0 = rep.pixelsWide / 16, x1 = rep.pixelsWide - x0
    let y0 = rep.pixelsHigh / 8, y1 = rep.pixelsHigh - 6
    let stepX = max(1, (x1 - x0) / 200), stepY = max(1, (y1 - y0) / 150)
    var y = y0
    while y < y1 {
        var x = x0
        while x < x1 {
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

/// Renders the notch section framed like the host, saves it, and asserts non-empty bitmap + size within target.
@MainActor
@discardableResult
func notchShot(_ name: String, center: AgentCenter, height: CGFloat = AgentsLayout.contentHeight, rtl: Bool = false,
               seed: ((AgentsUIState) -> Void)? = nil) -> NSBitmapImageRep? {
    func make() -> some View {
        NotchFrame(height: height) { NotchAgentsView(center: center, uiSeed: seed) }
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    }
    let size = CGSize(width: notchWidth, height: AgentsLayout.headerRowHeight + height + 12)
    guard let rep = bitmap(make(), size: size) else { check("\(name): bitmap created", false); return nil }
    let ink = inkFraction(rep)
    check("\(name): bitmap non-empty (ink \(String(format: "%.1f", ink * 100))%)", rep.pixelsWide > 0 && ink > 0.01)
    check("\(name): saved", save(rep, name))
    // The section view itself must not ask for more than its target frame (measured on the AppKit-hosted path; the
    // glass run uses a snapshot-only static layout whose ideal size is not meaningful).
    if useImageRenderer { return rep }
    let target = CGSize(width: contentWidth, height: height)
    let fit = sizeThatFits(NotchAgentsView(center: center, uiSeed: seed), in: target)
    check("\(name): view size \(Int(fit.width))x\(Int(fit.height)) within target \(Int(target.width))x\(Int(target.height))",
          fit.width <= target.width + 0.5 && fit.height <= target.height + 0.5)
    let wide = sizeThatFits(NotchAgentsView(center: center, uiSeed: seed), in: CGSize(width: contentWidth, height: 10_000))
    check("\(name): width never exceeds \(Int(contentWidth)) even with unlimited height (\(Int(wide.width)))", wide.width <= contentWidth + 0.5)
    return rep
}

/// Renders the section tall enough that the LazyVStack realises every row, and checks the realised row ids.
@MainActor
func tallShot(_ name: String, center: AgentCenter, height: CGFloat, rtl: Bool = false, expectRows: Int,
              seed: ((AgentsUIState) -> Void)? = nil) {
    var seen: Set<String> = []
    let view = NotchFrame(height: height) { NotchAgentsView(center: center, rowReporter: { seen = $0 }, uiSeed: seed) }
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    let size = CGSize(width: notchWidth, height: AgentsLayout.headerRowHeight + height + 12)
    let started = Date()
    guard let rep = bitmap(view, size: size, settle: 0.6) else { check("\(name): bitmap created", false); return }
    let elapsed = Date().timeIntervalSince(started)
    check("\(name): bitmap non-empty", rep.pixelsWide > 0 && inkFraction(rep) > 0.01)
    check("\(name): saved", save(rep, name))
    check("\(name): rendered rows (\(seen.count)) == fixture rows (\(expectRows))", seen.count == expectRows,
          "ids=\(seen.sorted().prefix(5))...")
    check("\(name): render time \(String(format: "%.2f", elapsed))s < 30s (software raster of material blurs over a tall bitmap)", elapsed < 30)
}

@MainActor
func settingsShot(_ name: String, center: AgentCenter, enabled: Bool = true, dark: Bool, height: CGFloat = 940) {
    let view = Form {
        AgentsSettingsSection(center: center, isEnabled: .constant(enabled), approvalTimeoutSeconds: .constant(90))
    }
    .formStyle(.grouped)
    .frame(width: AgentsLayout.settingsWidth, height: height)
    let size = CGSize(width: AgentsLayout.settingsWidth, height: height)
    AgentsSurfaceConfig.resetCounts()
    guard let rep = bitmap(view, size: size, dark: dark, forceAppKit: true) else { check("\(name): bitmap created", false); return }
    if AgentsSurfaceConfig.wantsGlass {
        check("\(name): glass path taken (\(AgentsSurfaceConfig.counts[.glass, default: 0]) glass surfaces)", AgentsSurfaceConfig.counts[.glass, default: 0] > 0)
        if inkFraction(rep) <= 0.01 {
            print("SKIP  \(name): Liquid Glass cannot be captured offscreen through the Form's AppKit host (blank bitmap); path asserted instead")
            return
        }
    }
    check("\(name): bitmap non-empty", rep.pixelsWide > 0 && inkFraction(rep) > 0.01)
    check("\(name): saved", save(rep, name))
    let fit = sizeThatFits(Form { AgentsSettingsSection(center: center, isEnabled: .constant(enabled), approvalTimeoutSeconds: .constant(90)) }.formStyle(.grouped),
                           in: CGSize(width: AgentsLayout.settingsWidth, height: 10_000))
    check("\(name): width \(Int(fit.width)) within \(Int(AgentsLayout.settingsWidth))", fit.width <= AgentsLayout.settingsWidth + 0.5)
}

// MARK: - Main

@main
struct SnapshotMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if CommandLine.arguments.count > 1 { outDir = CommandLine.arguments[1] }
        if AgentsSurfaceConfig.mode == .forceGlass && !AgentsSurfaceConfig.glassAvailable {
            print("SKIP  glass surface run: needs macOS 26 or newer (fallback run still covers the layout)")
            exit(0)
        }
        print("Surface path: \(AgentsSurfaceConfig.wantsGlass ? "Liquid Glass (macOS 26)" : "material fallback")")
        useImageRenderer = AgentsSurfaceConfig.wantsGlass
        if useImageRenderer { warmUpGlass(); AgentsSurfaceConfig.snapshotStatic = true }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        print("Output: \(outDir)")

        let dashboard = AgentCenter.preview(sessions: mixedSessions(4), hooks: installedHooks())
        dashboard.usageReport = AgentUsageReport(records: [AgentUsageRecord(id: "preview", kind: .claudeCode, sessionID: "s0", project: "Toplet", model: "Claude", at: ago(120), tokens: AgentTokenTotals(input: 12000, output: 2400, cacheRead: 8000, cacheWrite: 1000))], updatedAt: now)
        dashboard.quotaReadings = [AgentQuotaReading(kind: .claudeCode, fiveHourPercent: 43, sevenDayPercent: 68, fiveHourReset: now.addingTimeInterval(3600), sevenDayReset: now.addingTimeInterval(86400), todayEstimatedCost: 1.42, observedAt: now)]
        notchShot("dashboard_usage", center: dashboard, height: 410, seed: { $0.dashboardTab = .usage })
        dashboard.activityNotices = [AgentActivityNotice(key: SessionKey(kind: .claudeCode, id: "s0"), project: "Toplet", category: .completed, at: ago(15))]
        notchShot("dashboard_alerts", center: dashboard, height: 320, seed: { $0.dashboardTab = .alerts })
        notchShot("dashboard_focus", center: dashboard, height: 320, seed: { $0.dashboardTab = .focus })

        if ProcessInfo.processInfo.environment["ATOLL_DASHBOARD_ONLY"] == "1" {
            runClockAsserts()
            runClosedIndicator()
            print("Summary: \(passes) passed, \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }

        // (a) empty, no hooks
        notchShot("ui_a_empty_nohooks_h208", center: AgentCenter.preview(hooks: .notInstalled))
        notchShot("ui_a_empty_nohooks_h168", center: AgentCenter.preview(hooks: .notInstalled), height: AgentsLayout.minimumContentHeight)
        notchShot("ui_a_empty_hooks_codexhint", center: AgentCenter.preview(hooks: .installed(claude: true, codex: true)))

        // (b) 1 running + 1 needs-permission with a Bash approval card
        let run = session(.claudeCode, "s-run", "Toplet", status: .running, title: "Add the Agents tab",
                          tool: ToolActivity(name: "Edit", summary: "Package.swift", startedAt: ago(8)), since: 160,
                          tasks: Array(fixtureTasks().prefix(4)))
        let need = session(.claudeCode, "s-need", "website", status: .needsPermission, title: "Fix the checkout flow", since: 31)
        let ap = approval(need, summary: "rm -rf node_modules && npm ci",
                          detail: "rm -rf node_modules && npm ci\n# cwd: ~/Desktop/github/website\n# description: Reinstall dependencies from the lockfile",
                          suggestions: [PermissionSuggestion(id: 0, label: "Always allow Bash(npm ci:*)"), PermissionSuggestion(id: 1, label: "Always allow Bash(rm:*) in this project")])
        let cB = AgentCenter.preview(sessions: [need, run], pending: [ap], hooks: installedHooks())
        notchShot("ui_b_running_and_approval_h208", center: cB)
        notchShot("ui_b_running_and_approval_h168", center: cB, height: AgentsLayout.minimumContentHeight)
        notchShot("ui_b_approval_expanded", center: cB, height: 330, seed: { $0.expandedApprovals = [ap.id] })
        notchShot("ui_b_always_allow_confirm", center: cB, height: 330, seed: { $0.alwaysAllow = AlwaysAllowRequest(approvalID: ap.id, suggestion: ap.suggestions[0]) })
        notchShot("ui_b_toast", center: cB, seed: { $0.toast = "Could not find the terminal for website. Open it manually." })
        // unverified approval: session is passive
        let passiveNeed = session(.codex, "s-pass", "scratch", status: .needsPermission, live: false, prompt: "run the migration", since: 12)
        let apUnv = approval(passiveNeed, tool: "shell", summary: "psql -c 'drop table users'", detail: nil, expiresIn: 8)
        notchShot("ui_b_unverified_approval", center: AgentCenter.preview(sessions: [passiveNeed], pending: [apUnv], hooks: installedHooks()))
        // approval whose session is unknown
        let ghost = PendingApproval(sessionKey: SessionKey(kind: .claudeCode, id: "ghost"), tool: "Write", summary: "/etc/hosts", expiresAt: now.addingTimeInterval(40))
        notchShot("ui_b_unknown_session_approval", center: AgentCenter.preview(sessions: [], pending: [ghost], hooks: installedHooks()))

        // (c) 12 mixed sessions (visual at target size, full list tall)
        let mixed12 = mixedSessions(12)
        let cC = AgentCenter.preview(sessions: mixed12, pending: [], hooks: installedHooks())
        notchShot("ui_c_12_sessions_top_h208", center: cC)
        tallShot("ui_c_12_sessions_full", center: cC, height: 900, expectRows: 12)

        // (d) expanded session with tasks and subagents
        let full = session(.claudeCode, "s-full", "Toplet", status: .running, title: "Ship the hooks installer",
                           tool: bash("swift build -c release", 23), since: 400, tasks: fixtureTasks(), subs: fixtureSubagents(),
                           model: "claude-opus-4", mode: "acceptEdits",
                           lastText: "I added the backup step and the marker. Next I am wiring the uninstall path so only marked entries are removed, then I will run the parse-failure tests.")
        var withUsage = full; withUsage.usage = UsageSnapshot(costUSD: 1.42, contextUsedPercent: 63, source: "statusline")
        let cD = AgentCenter.preview(sessions: [withUsage, run], hooks: installedHooks())
        notchShot("ui_d_expanded_session_h208", center: cD, seed: { $0.expandedSessions = [withUsage.id] })
        tallShot("ui_d_expanded_session_full", center: cD, height: 520, expectRows: 2, seed: { $0.expandedSessions = [withUsage.id] })
        let passiveExp = session(.codex, "s-px", "notes-app", status: .idle, live: false, prompt: "Draft the changelog", since: 900)
        tallShot("ui_d_expanded_passive", center: AgentCenter.preview(sessions: [passiveExp], hooks: .notInstalled), height: 330, expectRows: 1,
                 seed: { $0.expandedSessions = [passiveExp.id] })

        // (e) board with 3 sections and tasks
        let boardE = fixtureBoard()
        let cE = AgentCenter.preview(sessions: [run], board: boardE, hooks: installedHooks())
        notchShot("ui_e_board_h208", center: cE)
        tallShot("ui_e_board_full", center: cE, height: 560, expectRows: 1)
        notchShot("ui_e_board_editing", center: cE, height: 420, seed: {
            let t = boardE[0].tasks[1]; $0.editingTask = t.id; $0.editTitle = t.title; $0.editNotes = "Check the CI log first"
            $0.addingSection = true; $0.newSectionDraft = "Backlog"
        })
        notchShot("ui_e_board_empty", center: AgentCenter.preview(hooks: installedHooks()), height: AgentsLayout.minimumContentHeight)

        // (f) long / RTL / emoji strings
        let longName = "a-really-long-project-name-that-keeps-going-and-going-and-going-until-it-must-truncate"
        let s1 = session(.claudeCode, "l1", longName, cwd: "\(NSHomeDirectory())/Desktop/github/org/\(longName)/packages/core", status: .running,
                         title: "Refactor " + String(repeating: "the extraordinarily verbose authentication middleware ", count: 6),
                         tool: ToolActivity(name: "mcp__github__create_pull_request_review_comment", summary: String(repeating: "x", count: 200), startedAt: ago(75)),
                         tasks: [AgentTask(id: "1", title: String(repeating: "A very long task title ", count: 8), status: .inProgress, order: 0)],
                         lastText: String(repeating: "Long assistant message that should clamp to three lines. ", count: 12))
        let s2 = session(.codex, "l2", "مشروع-التطبيق", cwd: "\(NSHomeDirectory())/Documents/مشروع-التطبيق", status: .waitingInput,
                         title: "أضف وضع الظلام إلى لوحة التحكم وأصلح مشكلة تسجيل الدخول", since: 70)
        let s3 = session(.claudeCode, "l3", "פרויקט", status: .idle, prompt: "תקן את הבאג בטופס ההרשמה 🐛🚀 and then ship it", since: 400)
        let s4 = session(.codex, "l4", "🚀 launch-day 🎉", status: .done, live: false, prompt: "Emoji 👩‍💻👨🏽‍🚀 test with ZWJ sequences and combining marks é́", since: 4000)
        let apLong = approval(s2, tool: "mcp__very_long_tool_name__do_something", summary: String(repeating: "قم بتشغيل الأمر التالي ", count: 12),
                              detail: String(repeating: "echo 'line with unicode ✓ λ → 🚀'\n", count: 14),
                              suggestions: [PermissionSuggestion(id: 0, label: "Always allow " + String(repeating: "very long rule ", count: 8))])
        var boardF = fixtureBoard()
        boardF[0].tasks.append(BoardTask(title: "مهمة بالعربية: راجع الطلب 🧾 " + String(repeating: "طويلة ", count: 20), notes: String(repeating: "ملاحظات ", count: 30)))
        boardF.append(BoardSection(title: String(repeating: "Section with a very long name ", count: 5) + "🧪", tasks: [BoardTask(title: String(repeating: "Long ", count: 60))]))
        let cF = AgentCenter.preview(sessions: [s1, s2, s3, s4], pending: [apLong], board: boardF, hooks: installedHooks())
        notchShot("ui_f_long_strings_ltr_h208", center: cF)
        notchShot("ui_f_long_strings_rtl_h208", center: cF, rtl: true)
        tallShot("ui_f_long_strings_ltr_full", center: cF, height: 1100, expectRows: 4, seed: { $0.expandedSessions = [s1.id]; $0.expandedApprovals = [apLong.id] })
        tallShot("ui_f_long_strings_rtl_full", center: cF, height: 1100, rtl: true, expectRows: 4, seed: { $0.expandedSessions = [s1.id]; $0.expandedApprovals = [apLong.id] })

        // 30 sessions + 3 approvals: performance and row count
        let many = mixedSessions(30)
        let manyAp = many.filter { $0.status == .needsPermission && $0.isLive }.prefix(3).map { approval($0, summary: "npm run build") }
        tallShot("ui_perf_30_sessions", center: AgentCenter.preview(sessions: many, pending: Array(manyAp), board: fixtureBoard(), hooks: installedHooks()),
                 height: 2400, expectRows: 30)
        check("ui_perf: row ids are unique", Set(many.map(\.id)).count == 30)

        // (g) settings
        let cG = AgentCenter.preview(sessions: mixed12, hooks: .installed(claude: true, codex: true))
        cG.isRunning = false
        settingsShot("ui_g_settings_hooks_installed_dark", center: cG, dark: true)
        settingsShot("ui_g_settings_hooks_installed_light", center: cG, dark: false)
        let cG2 = AgentCenter.preview(hooks: .notInstalled)
        settingsShot("ui_g_settings_not_installed_light", center: cG2, dark: false)
        settingsShot("ui_g_settings_disabled_dark", center: cG2, enabled: false, dark: true, height: 420)
        let cG3 = AgentCenter.preview(hooks: .error("~/.claude/settings.json is not valid JSON; Toplet did not touch it."))
        settingsShot("ui_g_settings_error_dark", center: cG3, dark: true)
        let previewText = "--- ~/.claude/settings.json\n+++ ~/.claude/settings.json (after install)\n@@ \"hooks\" @@\n+  \"PermissionRequest\": [{\n+    \"matcher\": \"\",\n+    \"hooks\": [{ \"type\": \"command\", \"command\": \"/usr/bin/nc -U ~/.atoll/run/agent.sock # atoll-agents\" }]\n+  }],\n"
        if let rep = bitmap(HookPreviewSheet(text: previewText, onClose: {}).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 560, height: 360), dark: false) {
            check("ui_g_preview_sheet: saved", save(rep, "ui_g_preview_sheet_light"))
            let ink = inkFraction(rep, threshold: 0.02); check("ui_g_preview_sheet: bitmap non-empty (ink \(String(format: "%.1f", ink * 100))%)", rep.pixelsWide > 0 && ink > 0.05)
        }

        runExtraSuites()

        print("\nSummary: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
