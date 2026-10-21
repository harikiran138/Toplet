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

// The BOARD: the user's own sections and small tasks. Everything is routed through `BoardActions`, so these views
// never touch AgentCenter directly.

struct BoardActions {
    var addSection: (String) -> Void
    var renameSection: (UUID, String) -> Void
    var deleteSection: (UUID) -> Void
    var toggleCollapsed: (UUID) -> Void
    var addTask: (UUID, String) -> Void
    var toggleTask: (UUID) -> Void
    var deleteTask: (UUID) -> Void
    var updateTask: (UUID, String, String) -> Void
    var startTask: (BoardTask, AgentKind) -> Void
    var moveTask: (UUID, UUID, Int) -> Void          // task, destination section, index
}

struct BoardView: View {
    let board: [BoardSection]
    let sessionsByID: [String: AgentSession]
    @ObservedObject var ui: AgentsUIState
    var focus: FocusState<AgentsFocus?>.Binding
    let actions: BoardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !ui.boardCollapsed {
                if ui.addingSection { newSectionField }
                if board.isEmpty && !ui.addingSection {
                    emptyBoard
                } else {
                    ForEach(board) { section in
                        BoardSectionView(section: section, sessionsByID: sessionsByID, ui: ui, focus: focus, actions: actions)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { ui.boardCollapsed.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(ui.boardCollapsed ? 0 : 90))
                    SectionLabel(title: "Board", count: board.reduce(0) { $0 + $1.tasks.filter { !$0.isDone }.count })
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: AgentsTheme.minTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ui.boardCollapsed ? "Expand board" : "Collapse board")
            Spacer()
            if !ui.boardCollapsed {
                Button {
                    ui.addingSection = true
                    focus.wrappedValue = .newSection
                } label: {
                    Label("Add section", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(AgentsButtonStyle(kind: .link))
                .accessibilityLabel("Add section")
            }
        }
        .padding(.horizontal, 2)
    }

    private var newSectionField: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.plus").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Section name", text: $ui.newSectionDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focus, equals: .newSection)
                .onSubmit(commitNewSection)
                .onExitCommand { cancelNewSection() }
            Button("Add", action: commitNewSection)
                .buttonStyle(AgentsButtonStyle(kind: .primary))
                .disabled(ui.newSectionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", action: cancelNewSection).buttonStyle(AgentsButtonStyle(kind: .quiet))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .agentsGlass()
    }

    private func commitNewSection() {
        let t = ui.newSectionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { actions.addSection(t) }
        cancelNewSection()
    }

    private func cancelNewSection() {
        ui.newSectionDraft = ""
        ui.addingSection = false
        focus.wrappedValue = nil
    }

    private var emptyBoard: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.3.group").font(.system(size: 15)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("No sections yet").font(.system(size: 12, weight: .semibold))
                Text("Keep small tasks here and start them with Claude Code or Codex.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("New section") { ui.addingSection = true; focus.wrappedValue = .newSection }
                .buttonStyle(AgentsButtonStyle(kind: .quiet))
        }
        .padding(12)
        .agentsGlass()
    }
}

struct BoardSectionView: View {
    let section: BoardSection
    let sessionsByID: [String: AgentSession]
    @ObservedObject var ui: AgentsUIState
    var focus: FocusState<AgentsFocus?>.Binding
    let actions: BoardActions
    @Environment(\.agentsMotion) private var m

    private var isDropTarget: Bool { ui.dropTarget == .section(section.id) }
    private var dropProgress: Double {
        guard isDropTarget else { return 0 }
        if let t = m.frozenTime { return m.animates ? AgentsPose.spring(t, AgentsMotion.dropTargetSpring) : 1 }
        return 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if ui.confirmDeleteSection == section.id { deleteConfirm }
            if !section.isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.tasks.enumerated()), id: \.element.id) { index, task in
                        if ui.editingTask == task.id {
                            TaskEditorRow(task: task, ui: ui, focus: focus, actions: actions)
                        } else {
                            TaskRowView(task: task, sectionID: section.id, index: index,
                                        linked: task.linkedSessionID.flatMap { sessionsByID[$0] },
                                        ui: ui, focus: focus, actions: actions)
                                .transition(.agentsReveal(animates: m.animates))
                        }
                    }
                    addTaskRow
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .agentsGlass()
        .overlay(
            RoundedRectangle(cornerRadius: AgentsTheme.cardRadius, style: .continuous)
                .strokeBorder(AgentsTheme.accent.opacity(0.9 * min(1, dropProgress)), lineWidth: 2)
                .allowsHitTesting(false)
        )
        .scaleEffect(m.animates ? 1 + 0.015 * dropProgress : 1)
        .agentsAnimation(AgentsMotion.dropTarget, value: ui.dropTarget, animates: m.animates && !m.isFrozen)
        .dropDestination(for: String.self) { items, _ in
            ui.dropTarget = nil
            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
            actions.moveTask(id, section.id, section.tasks.count)
            return true
        } isTargeted: { targeted in
            if targeted { if ui.dropTarget == nil { ui.dropTarget = .section(section.id) } }
            else if ui.dropTarget == .section(section.id) { ui.dropTarget = nil }
        }
        .contextMenu { sectionMenuItems }
        .scrollTransition(.animated(AgentsMotion.hover)) { content, phase in
            content.opacity(phase.isIdentity || !m.animates || AgentsSurfaceConfig.snapshotStatic ? 1 : 0.45).scaleEffect(phase.isIdentity || !m.animates || AgentsSurfaceConfig.snapshotStatic ? 1 : 0.97)
        }
        .accessibilityElement(children: .contain)
    }

    private var openCount: Int { section.tasks.filter { !$0.isDone }.count }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Button { actions.toggleCollapsed(section.id) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(section.isCollapsed ? 0 : 90))
                    .frame(width: AgentsTheme.minTarget, height: AgentsTheme.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(section.isCollapsed ? "Expand \(section.title)" : "Collapse \(section.title)")

            if ui.renamingSection == section.id {
                TextField("Section name", text: $ui.renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .focused(focus, equals: .renameSection(section.id))
                    .onSubmit(commitRename)
                    .onExitCommand { ui.renamingSection = nil; focus.wrappedValue = nil }
                Button("Save", action: commitRename).buttonStyle(AgentsButtonStyle(kind: .link))
            } else {
                Text(verbatim: section.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2, perform: beginRename)
                    .accessibilityAddTraits(.isHeader)
                AgentsChip(text: section.tasks.isEmpty ? "empty" : "\(openCount) open", tint: Color.secondary)
            }
            Spacer(minLength: 4)
            AgentsMenu { sectionMenuItems } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: AgentsTheme.minTarget, height: AgentsTheme.minTarget)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Section options for \(section.title)")
        }
    }

    @ViewBuilder
    private var sectionMenuItems: some View {
        Button("Rename…", action: beginRename)
        Button(section.isCollapsed ? "Expand" : "Collapse") { actions.toggleCollapsed(section.id) }
        Divider()
        Button("Delete section…", role: .destructive) {
            if section.tasks.isEmpty { actions.deleteSection(section.id) } else { ui.confirmDeleteSection = section.id }
        }
    }

    private func beginRename() {
        ui.renameText = section.title
        ui.renamingSection = section.id
        focus.wrappedValue = .renameSection(section.id)
    }

    private func commitRename() {
        let t = ui.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && t != section.title { actions.renameSection(section.id, t) }
        ui.renamingSection = nil
        focus.wrappedValue = nil
    }

    private var deleteConfirm: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Delete \u{201C}\(section.title)\u{201D} and its \(section.tasks.count) task\(section.tasks.count == 1 ? "" : "s")?")
                .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Delete") { ui.confirmDeleteSection = nil; actions.deleteSection(section.id) }
                .buttonStyle(AgentsButtonStyle(kind: .destructive))
            Button("Cancel") { ui.confirmDeleteSection = nil }.buttonStyle(AgentsButtonStyle(kind: .quiet))
        }
        .padding(.vertical, 4)
    }

    private var addTaskRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).frame(width: AgentsTheme.minTarget)
            TextField("Add a task, press Return", text: ui.draftBinding(for: section.id))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focus, equals: .newTask(section.id))
                .onSubmit {
                    let t = (ui.taskDrafts[section.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    actions.addTask(section.id, t)
                    ui.taskDrafts[section.id] = ""
                    focus.wrappedValue = .newTask(section.id)
                }
                .accessibilityLabel("New task in \(section.title)")
        }
        .frame(minHeight: AgentsTheme.minTarget)
    }
}

struct TaskRowView: View {
    let task: BoardTask
    let sectionID: UUID
    let index: Int
    let linked: AgentSession?
    @ObservedObject var ui: AgentsUIState
    var focus: FocusState<AgentsFocus?>.Binding
    let actions: BoardActions
    @Environment(\.agentsMotion) private var m

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Button { actions.toggleTask(task.id) } label: {
                AgentsCheckbox(isDone: task.isDone, size: 16)
                    .frame(width: AgentsTheme.minTarget, height: AgentsTheme.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark \(task.title) as not done" : "Mark \(task.title) as done")

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: AgentsFormat.oneLine(task.title))
                    .font(.system(size: 12))
                    .strikethrough(task.isDone, color: Color.secondary)
                    .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !task.notes.isEmpty {
                    Text(verbatim: AgentsFormat.oneLine(task.notes))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, minHeight: AgentsTheme.minTarget, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: beginEdit)

            if let agent = task.agent {
                HStack(spacing: 4) {
                    if let linked { AgentsOrb(status: linked.status, dim: !linked.isLive, size: 12) }
                    AgentsChip(text: agent.shortName, systemImage: AgentsTheme.symbol(for: agent), tint: AgentsTheme.color(for: agent))
                }
                .help(linked == nil ? "Started with \(agent.displayName)" : "Running in \(linked!.projectName)")
            }
            if !task.isDone {
                AgentsMenu {
                    Button("Start with Claude Code…") { actions.startTask(task, .claudeCode) }
                    Button("Start with Codex…") { actions.startTask(task, .codex) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text("Start")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: AgentsTheme.minTarget)
                    .agentsInset(shape: .capsule)
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Start \(task.title) with an agent")
            }
            Button { actions.deleteTask(task.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .frame(width: AgentsTheme.minTarget, height: AgentsTheme.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(task.title)")
        }
        .agentsHover(ui.hoveredRow == task.id.uuidString, radius: AgentsTheme.innerRadius)
        .overlay(alignment: .top) { dropLine }
        .opacity(ui.draggingTask == task.id ? 0.4 : 1)
        .draggable(task.id.uuidString) {
            Text(verbatim: AgentsFormat.oneLine(task.title)).font(.system(size: 12)).padding(8).agentsInset(shape: .rounded(8))
        }
        .dropDestination(for: String.self) { items, _ in
            ui.dropTarget = nil
            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
            actions.moveTask(id, sectionID, index)
            return true
        } isTargeted: { targeted in
            if targeted { ui.dropTarget = .task(task.id) } else if ui.dropTarget == .task(task.id) { ui.dropTarget = nil }
        }
        .onHover { inside in
            if inside { ui.hoveredRow = task.id.uuidString } else if ui.hoveredRow == task.id.uuidString { ui.hoveredRow = nil }
        }
        .contextMenu {
            Button("Edit…", action: beginEdit)
            Button(task.isDone ? "Mark not done" : "Mark done") { actions.toggleTask(task.id) }
            if !task.isDone {
                Divider()
                Button("Start with Claude Code…") { actions.startTask(task, .claudeCode) }
                Button("Start with Codex…") { actions.startTask(task, .codex) }
            }
            Divider()
            Button("Delete", role: .destructive) { actions.deleteTask(task.id) }
        }
        .accessibilityElement(children: .contain)
    }

    /// Insertion line shown above the row a dragged task would land before.
    @ViewBuilder
    private var dropLine: some View {
        if ui.dropTarget == .task(task.id) {
            Capsule(style: .continuous)
                .fill(AgentsTheme.accent)
                .frame(height: 3)
                .scaleEffect(x: m.animates ? max(0.01, dropProgress) : 1, anchor: .leading)
                .offset(y: -2)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    private var dropProgress: Double {
        if let t = m.frozenTime { return AgentsPose.spring(t, AgentsMotion.dropTargetSpring) }
        return 1
    }

    private func beginEdit() {
        ui.editTitle = task.title
        ui.editNotes = task.notes
        ui.editingTask = task.id
        focus.wrappedValue = .editTaskTitle(task.id)
    }
}

struct TaskEditorRow: View {
    let task: BoardTask
    @ObservedObject var ui: AgentsUIState
    var focus: FocusState<AgentsFocus?>.Binding
    let actions: BoardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("Title", text: $ui.editTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .focused(focus, equals: .editTaskTitle(task.id))
                .onSubmit(save)
                .onExitCommand(perform: cancel)
            TextField("Notes", text: $ui.editNotes, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .lineLimit(1...3)
                .foregroundStyle(.secondary)
                .onExitCommand(perform: cancel)
            HStack(spacing: 6) {
                Button("Save", action: save).buttonStyle(AgentsButtonStyle(kind: .primary))
                    .disabled(ui.editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", action: cancel).buttonStyle(AgentsButtonStyle(kind: .quiet))
            }
        }
        .padding(AgentsTheme.cardPadding)
        .agentsInset(shape: .rounded(AgentsTheme.innerRadius))
        .padding(.vertical, 4)
    }

    private func save() {
        let t = ui.editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        actions.updateTask(task.id, t, ui.editNotes)
        ui.editingTask = nil
        focus.wrappedValue = nil
    }

    private func cancel() {
        ui.editingTask = nil
        focus.wrappedValue = nil
    }
}
