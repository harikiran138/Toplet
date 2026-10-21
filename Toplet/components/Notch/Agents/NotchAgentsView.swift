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

// The notch section "Agents": header, ATTENTION strip (approvals), SESSION LIST and the user's BOARD.
//
// Hosting contract (for the integration step):
//  - Add `case agents` to `NotchViews` and `case .agents: NotchAgentsView(center: AgentCenter.shared, ...)` next to
//    `case .llmUsage` in ContentView. The view fills whatever frame it is given (see `AgentsLayout` for the sizes it
//    is designed for: about 612 x 168...228 pt, recommended notch height 240) and scrolls vertically inside it.
//  - Pass `isActive: vm.notchState == .open` (and false while the tab is not selected). While inactive the view runs no
//    timer and plays no animation.
//  - `onOpenSettings` / `onInstallHooks` are closures into the host (open Atoll settings on the Agents page).
//  - `pickProjectFolder` defaults to an NSOpenPanel; the host may inject its own.

struct NotchAgentsView: View {
    @ObservedObject var center: AgentCenter
    var isActive: Bool
    var onOpenSettings: () -> Void
    var onInstallHooks: () -> Void
    var onRefreshUsage: () -> Void
    var pickProjectFolder: @MainActor () -> URL?
    /// Core's `acknowledge(_:)` / `acknowledgeAll()` (additive API, see the shim in AgentsComponents.swift).
    var onAcknowledge: (SessionKey) -> Void
    var onAcknowledgeAll: () -> Void
    /// Test hook: receives the ids of the session rows that are currently realised.
    var rowReporter: ((Set<String>) -> Void)?
    /// Test hook: pins the animation clock (film strips) and/or forces Reduce Motion.
    var motionOverride: AgentsMotionEnvironment?
    /// Reports (content height, visible scroll height) so the host can size the notch to fit what is on screen.
    var onContentFit: ((CGFloat, CGFloat) -> Void)?

    @StateObject private var ui: AgentsUIState
    @FocusState private var focus: AgentsFocus?
    @Namespace private var glassNS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var fit = AgentsFitBox()

    /// `uiSeed` presets the local view state once (expanded rows, drafts ...); used by the snapshot harness.
    init(center: AgentCenter,
         isActive: Bool = true,
         onOpenSettings: @escaping () -> Void = {},
         onInstallHooks: @escaping () -> Void = {},
         pickProjectFolder: @escaping @MainActor () -> URL? = { AgentsFolderPicker.pick() },
         onAcknowledge: @escaping (SessionKey) -> Void = { _ in },
         onAcknowledgeAll: @escaping () -> Void = {},
         rowReporter: ((Set<String>) -> Void)? = nil,
         motionOverride: AgentsMotionEnvironment? = nil,
         uiSeed: ((AgentsUIState) -> Void)? = nil,
         onRefreshUsage: @escaping () -> Void = {},
         onContentFit: ((CGFloat, CGFloat) -> Void)? = nil) {
        self.center = center
        self.isActive = isActive
        self.onOpenSettings = onOpenSettings
        self.onRefreshUsage = onRefreshUsage
        self.onInstallHooks = onInstallHooks
        self.pickProjectFolder = pickProjectFolder
        self.onAcknowledge = onAcknowledge
        self.onAcknowledgeAll = onAcknowledgeAll
        self.rowReporter = rowReporter
        self.motionOverride = motionOverride
        self.onContentFit = onContentFit
        _ui = StateObject(wrappedValue: {
            let state = AgentsUIState()
            uiSeed?(state)
            return state
        }())
    }

    // MARK: Motion environment

    private func motion(tick: Int) -> AgentsMotionEnvironment {
        if var o = motionOverride {
            o.isActive = o.isActive && isActive
            return o
        }
        return AgentsMotionEnvironment(isActive: isActive, reduceMotion: reduceMotion, tick: tick, frozenTime: nil)
    }

    private var animationsOn: Bool { motion(tick: 0).animates }

    /// The one repeating clock runs only while the notch section is active AND something on screen can use it:
    /// elapsed-time labels (sessions / approvals) or the empty-state hero.
    private var clockActive: Bool {
        guard isActive, motionOverride?.isFrozen != true else { return false }
        return center.focusTimer.deadline != nil || !center.sessions.isEmpty || !center.pending.isEmpty || !(motionOverride?.reduceMotion ?? reduceMotion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentsHeaderView(
                running: visibleSessions.filter { $0.status == .running }.count,
                needsYou: needsYouCount,
                onRefresh: { center.refreshDiscovery() },
                onSettings: onOpenSettings
            )
            TimelineView(AgentsTickSchedule(active: clockActive)) { context in
                content(now: motionOverride?.isFrozen == true ? (motionOverride?.frozenNow ?? Date()) : context.date)
                    .environment(\.agentsMotion, motion(tick: AgentsMotionEnvironment.tick(for: context.date)))
            }
        }
        .environment(\.agentsMotion, motion(tick: 0))
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottom) { toast }
        .transaction { t in if !animationsOn { t.animation = nil } }
        .sensoryFeedback(.success, trigger: ui.approveTick)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: ui.denyTick)
        .sensoryFeedback(.warning, trigger: ui.attentionTick)
        .onPreferenceChange(AgentsRowIDsKey.self) { rowReporter?($0) }
        .onPreferenceChange(AgentsContentHeightKey.self) { fit.content = $0; reportFit() }
        .onPreferenceChange(AgentsViewportHeightKey.self) { fit.viewport = $0; reportFit() }
        .onChange(of: center.lastNotice) { _, notice in
            if let notice, !notice.isEmpty { ui.showToast(notice) }
        }
        .onChange(of: attentionKeys) { old, new in announceNewAttention(added: new.subtracting(old)) }
        .onChange(of: center.pending.map(\.id)) { _, _ in prune() }
        .onChange(of: center.sessions.map(\.id)) { _, _ in prune() }
        .onChange(of: center.board.map(\.id)) { _, _ in prune() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
    }

    // MARK: Derived

    /// Core sorts attention first; "finished, not yet seen" goes right after the attention group, then everything else.
    private var visibleSessions: [AgentSession] {
        let all = center.sessions.filter { !ui.hiddenSessions.contains($0.id) }
        func rank(_ s: AgentSession) -> Int {
            if s.status == .needsPermission || s.status == .waitingInput || s.status == .failed { return 0 }
            if s.uiFinishedUnseen && (s.status == .idle || s.status == .done) { return 1 }
            return 2
        }
        return all.enumerated().sorted { (a, b) in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private var unseenCount: Int { center.sessions.filter { $0.uiFinishedUnseen && ($0.status == .idle || $0.status == .done) }.count }

    private var attentionKeys: Set<SessionKey> {
        var keys = Set(center.sessions.filter { $0.status == .needsPermission || $0.status == .waitingInput }.map(\.key))
        keys.formUnion(center.pending.map(\.sessionKey))
        return keys
    }

    private var needsYouCount: Int { attentionKeys.count }

    private var sessionsByKey: [SessionKey: AgentSession] {
        Dictionary(center.sessions.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func reportFit() {
        guard fit.content > 0, fit.viewport > 0 else { return }
        onContentFit?(fit.content, fit.viewport)
    }

    private func prune() {
        ui.prune(sessionIDs: Set(center.sessions.map(\.id)), approvalIDs: Set(center.pending.map(\.id)),
                 sectionIDs: Set(center.board.map(\.id)))
    }

    private func announceNewAttention(added: Set<SessionKey>) {
        guard !added.isEmpty else { return }
        ui.attentionTick += 1
        let byKey = sessionsByKey
        let names = added.compactMap { byKey[$0]?.projectName }.sorted()
        let text = names.isEmpty ? "An agent needs you" : names.joined(separator: ", ") + (names.count == 1 ? " needs permission" : " need permission")
        AccessibilityNotification.Announcement(text).post()
    }

    private func moveFocus(from id: String, _ direction: MoveCommandDirection) {
        let ids = visibleSessions.map(\.id)
        guard let i = ids.firstIndex(of: id) else { return }
        switch direction {
        case .down: if i + 1 < ids.count { focus = .session(ids[i + 1]) }
        case .up: if i > 0 { focus = .session(ids[i - 1]) }
        default: break
        }
    }

    private func copy(_ path: String) {
        AgentsClipboard.copy(path)
        ui.showToast("Copied path")
    }

    // MARK: Content

    @ViewBuilder
    private func scroller<C: View>(@ViewBuilder _ makeInner: () -> C) -> some View {
        let inner = makeInner()
        if AgentsSurfaceConfig.snapshotStatic {
            // Test-only: ImageRenderer cannot rasterise ScrollView, so glass snapshots use a clipped plain stack.
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 8) { inner }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) { inner }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: AgentsContentHeightKey.self, value: g.size.height)
                    })
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: AgentsViewportHeightKey.self, value: g.size.height)
            })
        }
    }

    private func content(now: Date) -> some View {
        let byKey = sessionsByKey
        let pendingKeys = Set(center.pending.map(\.sessionKey))
        let shown = visibleSessions
        let layoutKey = center.pending.map { $0.id.uuidString } + shown.map(\.id)
        return scroller {
            AgentsGlassGroup(spacing: 4) {
                if !center.pending.isEmpty {
                    attentionStrip(now: now, byKey: byKey)
                }

                banners

                AgentsDashboardView(center: center, ui: ui, now: now, onRefreshUsage: onRefreshUsage)

                if ui.dashboardTab == .activity {
                    sessionsSection(now: now, shown: shown, pendingKeys: pendingKeys)
                }

                codexHint

                if ui.dashboardTab == .activity {
                BoardView(board: center.board, sessionsByID: Dictionary(center.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                          ui: ui, focus: $focus, actions: boardActions)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }
            }
            .animation(animationsOn ? AgentsMotion.cardDrop : nil, value: layoutKey)
        }
    }

    private func attentionStrip(now: Date, byKey: [SessionKey: AgentSession]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BadgeBounce(trigger: center.pending.count) {
                SectionLabel(title: "Needs you", count: center.pending.count, tint: AgentsTheme.attention)
            }
            .padding(.horizontal, 2)
            ForEach(center.pending) { approval in
                ApprovalCardView(
                    approval: approval,
                    session: byKey[approval.sessionKey],
                    now: now,
                    glassNamespace: glassNS,
                    isExpanded: ui.expandedApprovals.contains(approval.id),
                    alwaysAllow: ui.alwaysAllow?.approvalID == approval.id ? ui.alwaysAllow?.suggestion : nil,
                    onToggleDetail: { withAnimation(animationsOn ? AgentsMotion.rowMorph : nil) { ui.toggleApproval(approval.id) } },
                    onDecide: { decision in
                        ui.alwaysAllow = nil
                        switch decision {
                        case .allowOnce, .allowAlways: ui.approveTick += 1
                        case .deny: ui.denyTick += 1
                        case .letTerminalDecide: break
                        }
                        center.decide(approval.id, decision)
                    },
                    onRequestAlways: { ui.alwaysAllow = AlwaysAllowRequest(approvalID: approval.id, suggestion: $0) },
                    onCancelAlways: { ui.alwaysAllow = nil }
                )
                .transition(.agentsDrop(animates: animationsOn))
            }
        }
        .background { AttentionGlow(tint: AgentsTheme.attention).padding(-20) }
    }

    @ViewBuilder
    private func sessionsSection(now: Date, shown: [AgentSession], pendingKeys: Set<SessionKey>) -> some View {
        if center.sessions.isEmpty {
            if center.pending.isEmpty { emptySessions }
        } else {
            HStack {
                Button { ui.sessionsCollapsed.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(ui.sessionsCollapsed ? 0 : 90))
                            .agentsAnimation(AgentsMotion.hover, value: ui.sessionsCollapsed, animates: animationsOn)
                        SectionLabel(title: "Sessions", count: shown.count)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                    .frame(minHeight: AgentsTheme.minTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ui.sessionsCollapsed ? "Expand sessions" : "Collapse sessions")
                Spacer()
                if unseenCount > 0 {
                    Button { onAcknowledgeAll() } label: {
                        Label("Mark all as seen", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(AgentsButtonStyle(kind: .link, prominentTint: AgentsTheme.success))
                    .help("Clear the green \"finished\" marks")
                }
                if !ui.hiddenSessions.isEmpty {
                    Button("Show \(ui.hiddenSessions.count) hidden") { ui.hiddenSessions = [] }
                        .buttonStyle(AgentsButtonStyle(kind: .link))
                }
            }
            if !ui.sessionsCollapsed {
                ForEach(shown) { session in
                    SessionRowView(
                        session: session,
                        now: now,
                        glassNamespace: glassNS,
                        isExpanded: ui.expandedSessions.contains(session.id),
                        isHovered: ui.hoveredRow == session.id,
                        hasPending: pendingKeys.contains(session.key),
                        subagentsOpen: ui.expandedSubagents.contains(session.id),
                        focus: $focus,
                        onToggle: {
                            if session.uiFinishedUnseen { onAcknowledge(session.key) }
                            withAnimation(animationsOn ? AgentsMotion.rowMorph : nil) { ui.toggleSession(session.id) }
                        },
                        onToggleSubagents: {
                            withAnimation(animationsOn ? AgentsMotion.rowMorph : nil) {
                                if ui.expandedSubagents.contains(session.id) { ui.expandedSubagents.remove(session.id) } else { ui.expandedSubagents.insert(session.id) }
                            }
                        },
                        onAcknowledge: { onAcknowledge(session.key) },
                        onJump: { center.jump(to: session.key) },
                        onCopyPath: { copy(session.cwd) },
                        onRefresh: { center.refreshDiscovery() },
                        onHide: { ui.hiddenSessions.insert(session.id) },
                        onHover: { inside in
                            if inside { ui.hoveredRow = session.id } else if ui.hoveredRow == session.id { ui.hoveredRow = nil }
                        },
                        onMove: { moveFocus(from: session.id, $0) }
                    )
                }
            }
        }
    }

    // MARK: Banners and empty state

    @ViewBuilder
    private var banners: some View {
        if let error = center.serverError, !error.isEmpty {
            AgentsBanner(systemImage: "exclamationmark.triangle.fill", tint: AgentsTheme.attention,
                         title: "Live channel unavailable",
                         detail: error + " Sessions are still discovered passively.")
        }
        switch center.hooksState {
        case .notInstalled:
            AgentsBanner(systemImage: "bolt.horizontal.circle.fill", tint: AgentsTheme.accent,
                         title: "Live status and approvals need hooks",
                         detail: "Without them Toplet only sees sessions passively. Nothing is changed until you review and install.",
                         actionTitle: "Install…", action: onInstallHooks)
        case .installed:
            EmptyView()
        case .error(let message):
            AgentsBanner(systemImage: "xmark.octagon.fill", tint: AgentsTheme.danger,
                         title: "Hooks problem", detail: message,
                         actionTitle: "Settings…", action: onOpenSettings)
        }
    }

    /// Low-priority hint, shown below the sessions so it never pushes an approval or a session off screen.
    @ViewBuilder
    private var codexHint: some View {
        if case .installed(_, let codex) = center.hooksState, codex, !ui.codexHintDismissed,
           !center.sessions.contains(where: { $0.key.kind == .codex && $0.isLive }) {
            AgentsBanner(systemImage: "checkmark.shield.fill", tint: AgentsTheme.color(for: .codex),
                         title: "Codex: trust the Toplet hook once",
                         detail: "In Codex run /hooks and trust the Toplet entry. Until then Codex ignores it.",
                         onDismiss: { ui.codexHintDismissed = true })
        }
    }

    private var emptySessions: some View {
        HStack(spacing: 12) {
            EmptyHero()
            VStack(alignment: .leading, spacing: 2) {
                Text("No agents found").font(.system(size: 12.5, weight: .semibold))
                Text("Start Claude Code or Codex in a terminal or editor and it shows up here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentsGlass()
        .accessibilityElement(children: .combine)
    }

    // MARK: Toast

    @ViewBuilder
    private var toast: some View {
        if let text = ui.toast {
            Text(verbatim: text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .agentsGlass(shape: .capsule)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityAddTraits(.isStaticText)
        }
    }

    // MARK: Board actions

    private var boardActions: BoardActions {
        BoardActions(
            addSection: { center.addSection(title: $0) },
            renameSection: { center.renameSection($0, to: $1) },
            deleteSection: { center.deleteSection($0) },
            toggleCollapsed: { center.toggleCollapsed($0) },
            addTask: { center.addTask(in: $0, title: $1) },
            toggleTask: { center.toggleTask($0) },
            deleteTask: { center.deleteTask($0) },
            updateTask: { center.updateTask($0, title: $1, notes: $2) },
            startTask: { task, agent in
                if let cwd = pickProjectFolder() { center.startQuickTask(task.id, with: agent, cwd: cwd) }
            },
            moveTask: { id, section, index in
                // A drop can carry any string: only act on ids that really are tasks on our board.
                guard center.board.contains(where: { $0.tasks.contains(where: { $0.id == id }) }),
                      center.board.contains(where: { $0.id == section }) else { return }
                center.moveTask(id, toSection: section, at: index)
            }
        )
    }
}

// MARK: - Content fit

/// Natural height of the scrolling content (not limited by the notch).
struct AgentsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Height of the visible scroll area the notch currently gives the content.
struct AgentsViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Last measured heights. Plain (unpublished) values: they only feed `onContentFit` and must never re-render the view.
final class AgentsFitBox: ObservableObject {
    var content: CGFloat = 0
    var viewport: CGFloat = 0
}

// MARK: - Header

struct AgentsHeaderView: View {
    let running: Int
    let needsYou: Int
    let onRefresh: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Agents").font(.headline).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
            if running > 0 {
                CountPill(count: running, word: "running", color: AgentsTheme.success)
                    .transition(.scale.combined(with: .opacity))
            }
            if needsYou > 0 {
                CountPill(count: needsYou, word: "needs you", color: AgentsTheme.attention)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer(minLength: 4)
            // Standalone glass controls: one container so the two circles sample together and can blend.
            AgentsGlassGroup(spacing: 12) {
                HStack(spacing: 8) {
                    AgentsIconButton(systemName: "arrow.clockwise", label: "Refresh sessions", glass: true, action: onRefresh)
                    AgentsIconButton(systemName: "gearshape", label: "Agents settings", glass: true, action: onSettings)
                }
            }
        }
        .frame(height: AgentsTheme.minTarget)
        .padding(.horizontal, 2)
    }
}

/// Empty-state hero symbol: breathes gently on the shared clock.
struct EmptyHero: View {
    @Environment(\.agentsMotion) private var m

    var body: some View {
        let b: Double = m.animates ? (m.frozenTime.map { AgentsPose.wave($0, period: 2.4) } ?? (m.breathOn ? 1 : 0)) : 0.5
        Image(systemName: "terminal")
            .font(.system(size: 22, weight: .light))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .scaleEffect(m.animates ? 0.94 + 0.12 * b : 1)
            .opacity(m.animates ? 0.55 + 0.45 * b : 0.8)
            .animation(m.animates && !m.isFrozen ? AgentsMotion.breathe : nil, value: m.breathOn)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}
