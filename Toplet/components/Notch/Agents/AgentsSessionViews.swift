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

// The SESSION LIST: one row per AgentSession. No timers in here: `now` and the animation tick come from the one shared
// TimelineView of NotchAgentsView (see AgentsMotion.swift).

struct SessionRowView: View {
    let session: AgentSession
    let now: Date
    let glassNamespace: Namespace.ID
    let isExpanded: Bool
    let isHovered: Bool
    let hasPending: Bool
    let subagentsOpen: Bool
    var focus: FocusState<AgentsFocus?>.Binding
    let onToggle: () -> Void
    let onToggleSubagents: () -> Void
    let onAcknowledge: () -> Void
    let onJump: () -> Void
    let onCopyPath: () -> Void
    let onRefresh: () -> Void
    let onHide: () -> Void
    let onHover: (Bool) -> Void
    let onMove: (MoveCommandDirection) -> Void

    @Environment(\.agentsMotion) private var m

    private var passive: Bool { !session.isLive }
    /// Finished since the user last looked (green check until acknowledged).
    private var finished: Bool { session.uiFinishedUnseen && (session.status == .idle || session.status == .done) }
    private var isFocused: Bool { focus.wrappedValue == .session(session.id) }

    /// State tint of the glass: orange = needs you, red = failed, green = running; nothing for idle/done/passive.
    private var rowTint: Color? {
        if finished { return AgentsTheme.success }
        switch session.status {
        case .needsPermission, .waitingInput: return AgentsTheme.attention
        case .failed: return AgentsTheme.danger
        case .running: return passive ? nil : AgentsTheme.success
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                summary
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggle)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Copy path", onCopyPath)
                // Secondary action: revealed on pointer hover (or keyboard focus) with a spring.
                let reveal = isHovered || isFocused
                AgentsIconButton(systemName: "doc.on.doc", label: "Copy path", action: onCopyPath)
                    .scaleEffect(m.animates ? (reveal ? 1 : 0.5) : 1)
                    .opacity(reveal ? 1 : 0)
                    .allowsHitTesting(reveal)
                    .accessibilityHidden(!reveal)
                    .agentsAnimation(AgentsMotion.hover, value: reveal, animates: m.animates)
                AgentsIconButton(systemName: "arrow.up.forward.app", label: "Jump to \(session.projectName)", action: jump)
            }
            if isExpanded {
                SessionDetailView(session: session, now: now, subagentsOpen: subagentsOpen, onToggleSubagents: onToggleSubagents)
                    .padding(.leading, 22)
                    .padding(.top, 8)
                    .padding(.trailing, 4)
                    .modifier(FrozenReveal())
                    .transition(.agentsReveal(animates: m.animates))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .agentsGlass(tint: rowTint, id: "session-\(session.id)", in: glassNamespace)
        .agentsHover(isHovered)
        .onHover(perform: onHover)
        .focusable()
        .focused(focus, equals: .session(session.id))
        .onMoveCommand(perform: onMove)
        // Space expands, Return jumps. Approvals are never reachable from here: they stay mouse-only.
        .onKeyPress(.space) { onToggle(); return .handled }
        .onKeyPress(.return) { jump(); return .handled }
        .contextMenu {
            Button("Copy path", action: onCopyPath)
            Button("Jump to terminal", action: jump)
            if finished { Button("Mark as seen", action: onAcknowledge) }
            Divider()
            Button("Refresh sessions", action: onRefresh)
            Button("Hide from list", action: onHide)
        }
        .opacity(passive ? 0.82 : 1)
        .scrollTransition(.animated(AgentsMotion.hover)) { content, phase in
            content.opacity(phase.isIdentity || !m.animates || AgentsSurfaceConfig.snapshotStatic ? 1 : 0.45).scaleEffect(phase.isIdentity || !m.animates || AgentsSurfaceConfig.snapshotStatic ? 1 : 0.97)
        }
        .preference(key: AgentsRowIDsKey.self, value: [session.id])
        .accessibilityElement(children: .contain)
    }

    private func jump() {
        if finished { onAcknowledge() }
        onJump()
    }

    // MARK: Collapsed summary

    private var summary: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentAppIdentity(kind: session.key.kind, hostBundleID: session.hostAppBundleID)
            AgentsOrb(status: session.status, dim: passive, finished: finished)
                .padding(.top, 3)
                .matchedGeometryEffect(id: "orb-\(session.id)", in: glassNamespace)
            VStack(alignment: .leading, spacing: 4) {
                // The path is the first thing to go when the row is tight (no ugly mid-word truncation).
                ViewThatFits(in: .horizontal) {
                    titleLine(showPath: true)
                    titleLine(showPath: false)
                }
                Text(verbatim: AgentsFormat.oneLine(headline))
                    .font(.system(size: 11.5))
                    .foregroundStyle(headline.isEmpty ? Color.secondary.opacity(0.7) : Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                activityLabel.agentsShimmer(active: session.status == .running)
                chips
            }
            .frame(maxWidth: 210, alignment: .trailing)
            .layoutPriority(1)
        }
        .frame(minHeight: AgentsTheme.minTarget, alignment: .top)
    }

    /// The row is titled by the user's latest prompt; the agent's own title/name are only fallbacks.
    private func titleLine(showPath: Bool) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: session.projectName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)
            AgentBadge(kind: session.key.kind)
            if let model = session.model, !model.isEmpty {
                Text(verbatim: AgentsFormat.modelTag(model))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help("Model: \(model)")
            }
            if passive {
                AgentsChip(text: "passive", systemImage: "eye", tint: Color.secondary)
                    .help("Found without hooks: estimated status, limited info, no approvals.")
            }
            if showPath {
                Text(verbatim: AgentsFormat.shortPath(session.cwd))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var headline: String {
        if let p = session.lastPrompt.flatMap(AgentText.userFacingPrompt), !p.isEmpty { return p }
        if let t = session.title.flatMap(AgentText.userFacingPrompt), !t.isEmpty { return t }
        if let n = session.name.flatMap(AgentText.userFacingPrompt), !n.isEmpty { return n }
        return "Session discovered · waiting for task details"
    }

    /// "~" marks times that are estimates (sessions seen without hooks).
    private var est: String { passive ? "~" : "" }

    @ViewBuilder
    private var activityLabel: some View {
        switch session.status {
        case _ where finished:
            tinted("Finished", clock: est + AgentsFormat.coarse(since: session.statusSince, now: now), color: AgentsTheme.success)
        case .needsPermission:
            tinted("Needs permission", clock: AgentsFormat.elapsed(since: session.statusSince, now: now), color: AgentsTheme.attention)
        case .waitingInput:
            tinted("Waiting for you", clock: AgentsFormat.elapsed(since: session.statusSince, now: now), color: AgentsTheme.attention)
        case .failed:
            tinted("Failed", clock: AgentsFormat.coarse(since: session.statusSince, now: now), color: AgentsTheme.danger)
        case .running, .starting:
            if let tool = session.currentTool {
                HStack(spacing: 4) {
                    Text(verbatim: tool.name)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !tool.summary.isEmpty {
                        Text(verbatim: AgentsFormat.oneLine(tool.summary))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(verbatim: AgentsFormat.elapsed(since: tool.startedAt, now: now))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            } else {
                tinted(session.status == .starting ? "Starting" : "Working", clock: est + AgentsFormat.elapsed(since: session.statusSince, now: now), color: AgentsTheme.success)
            }
        case .idle, .done, .stopped, .unknown:
            HStack(spacing: 4) {
                Text(verbatim: passive && session.status != .done ? "Seen" : session.status.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: est + AgentsFormat.coarse(since: passive ? session.lastEventAt : session.statusSince, now: now))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
    }

    private func tinted(_ text: String, clock: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color).lineLimit(1)
            Text(verbatim: clock).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(color.opacity(0.7)).fixedSize()
        }
    }

    @ViewBuilder
    private var chips: some View {
        let done = session.tasks.filter { $0.status == .completed }.count
        let runningSubs = session.subagents.filter { $0.status == .running }.count
        if !session.tasks.isEmpty || !session.subagents.isEmpty || hasPending {
            HStack(spacing: 4) {
                if hasPending {
                    AgentsChip(text: "approval", systemImage: "hand.raised.fill", tint: AgentsTheme.attention)
                }
                if !session.tasks.isEmpty {
                    ProgressChip(done: done, total: session.tasks.filter { $0.status != .cancelled }.count)
                }
                if !session.subagents.isEmpty {
                    AgentsChip(text: runningSubs > 0 ? "\(runningSubs)/\(session.subagents.count)" : "\(session.subagents.count)",
                               systemImage: "person.2.fill", tint: runningSubs > 0 ? AgentsTheme.success : Color.secondary)
                }
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = ["\(session.key.kind.displayName), \(session.projectName)", session.status.label]
        if passive { parts.append("passive, limited information") }
        if let tool = session.currentTool { parts.append("running \(tool.name) for \(AgentsFormat.elapsed(since: tool.startedAt, now: now))") }
        if finished { parts.append("finished, not yet seen") }
        parts.append(headline)
        if !session.tasks.isEmpty { parts.append("\(session.tasks.filter { $0.status == .completed }.count) of \(session.tasks.count) tasks done") }
        if !session.subagents.isEmpty { parts.append("\(session.subagents.count) subagents") }
        if hasPending { parts.append("approval pending") }
        return parts.joined(separator: ". ")
    }
}

/// In film strips (frozen clock) the detail is revealed with the closed-form spring pose instead of the live transition.
struct FrozenReveal: ViewModifier {
    @Environment(\.agentsMotion) private var m
    func body(content: Content) -> some View {
        if let t = m.frozenTime {
            content.modifier(RevealPose(progress: m.animates ? AgentsPose.spring(t, AgentsMotion.rowMorphSpring) : 1))
        } else {
            content
        }
    }
}

// MARK: - Expanded details

struct SessionDetailView: View {
    let session: AgentSession
    let now: Date
    var subagentsOpen = false
    var onToggleSubagents: () -> Void = {}
    private let maxTasks = 8
    private let maxSubagents = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            metaLine
            if let waiting = session.waitingFor, !waiting.isEmpty {
                Label { Text(verbatim: waiting).font(.system(size: 11)).lineLimit(2) } icon: {
                    Image(systemName: "hourglass").font(.system(size: 10))
                }
                .foregroundStyle(AgentsTheme.attention)
            }
            if !session.tasks.isEmpty { tasksBlock }
            if !session.subagents.isEmpty { subagentsBlock }
            if let text = session.lastAssistantText, !text.isEmpty { lastText(text) }
            if !session.isLive {
                Text("Passive: found without hooks, so Toplet sees only limited info and cannot approve for this session.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaLine: some View {
        let bits: [String] = [session.model, session.permissionMode.map { "mode: \($0)" },
                              session.surface == .unknown ? nil : surfaceName(session.surface),
                              usageText].compactMap { $0 }.filter { !$0.isEmpty }
        return Group {
            if !bits.isEmpty {
                Text(verbatim: bits.joined(separator: "  ·  "))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var usageText: String? {
        guard let u = session.usage else { return nil }
        var bits: [String] = []
        if let c = u.costUSD { bits.append(String(format: "$%.2f", c)) }
        if let p = u.contextUsedPercent { bits.append("ctx \(Int(p.rounded()))%") }
        return bits.isEmpty ? nil : bits.joined(separator: " ")
    }

    private func surfaceName(_ s: Surface) -> String {
        switch s {
        case .terminal: return "terminal"
        case .vscode: return "VS Code"
        case .jetbrains: return "JetBrains"
        case .desktopApp: return "desktop app"
        case .xcode: return "Xcode"
        case .headless: return "headless"
        case .background: return "background"
        case .unknown: return ""
        }
    }

    private var tasksBlock: some View {
        let ordered = session.tasks.sorted { $0.order < $1.order }
        let shown = Array(ordered.prefix(maxTasks))
        return VStack(alignment: .leading, spacing: 3) {
            SectionLabel(title: "Tasks", count: session.tasks.count)
            ForEach(shown) { task in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon(for: task.status))
                        .font(.system(size: 10.5))
                        .foregroundStyle(color(for: task.status))
                        .frame(width: 13)
                    Text(verbatim: task.status == .inProgress ? (task.activeForm ?? task.title) : task.title)
                        .font(.system(size: 11.5, weight: task.status == .inProgress ? .semibold : .regular))
                        .strikethrough(task.status == .completed || task.status == .cancelled, color: Color.white.opacity(0.3))
                        .foregroundStyle(task.status == .completed || task.status == .cancelled ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(task.title), \(statusWord(task.status))")
            }
            if ordered.count > shown.count {
                Text(verbatim: "+\(ordered.count - shown.count) more").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for s: TaskStatus) -> String {
        switch s {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func color(for s: TaskStatus) -> Color {
        switch s {
        case .pending: return Color.white.opacity(0.45)
        case .inProgress: return AgentsTheme.accent
        case .completed: return AgentsTheme.success.opacity(0.8)
        case .cancelled: return Color.white.opacity(0.3)
        }
    }

    private func statusWord(_ s: TaskStatus) -> String {
        switch s {
        case .pending: return "pending"
        case .inProgress: return "in progress"
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        }
    }

    private var subagentsBlock: some View {
        let shown = Array(session.subagents.prefix(maxSubagents))
        let running = session.subagents.filter { $0.status == .running }.count
        return VStack(alignment: .leading, spacing: 3) {
            Button(action: onToggleSubagents) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(subagentsOpen ? 90 : 0))
                    Text(verbatim: "\(session.subagents.count) subagent\(session.subagents.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold))
                    if running > 0 { AgentsChip(text: "\(running) running", tint: AgentsTheme.success) }
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: AgentsTheme.minTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(session.subagents.count) subagents")
            .accessibilityHint(subagentsOpen ? "Collapse" : "Expand")
            if subagentsOpen { ForEach(shown) { sub in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(subColor(sub.status)).frame(width: 6, height: 6).offset(y: -1).accessibilityHidden(true)
                    Text(verbatim: sub.type ?? "agent")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(verbatim: AgentsFormat.oneLine(sub.currentTool.map { "\($0.name) \($0.summary)" } ?? sub.lastText ?? sub.status.rawValue))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if sub.status == .running {
                        Text(verbatim: AgentsFormat.elapsed(since: sub.startedAt, now: now))
                            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Subagent \(sub.type ?? "agent"), \(sub.status.rawValue)")
            }
            if session.subagents.count > shown.count {
                Text(verbatim: "+\(session.subagents.count - shown.count) more").font(.system(size: 10.5)).foregroundStyle(.secondary)
            } }
        }
    }

    private func subColor(_ s: SubagentStatus) -> Color {
        switch s {
        case .running: return AgentsTheme.success
        case .idle: return Color.secondary
        case .waiting: return AgentsTheme.attention
        case .done: return Color.white.opacity(0.3)
        case .failed: return AgentsTheme.danger
        }
    }

    private func lastText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(AgentsTheme.color(for: session.key.kind).opacity(0.6)).frame(width: 2.5)
            Text(verbatim: text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Last message: \(text)")
    }
}
