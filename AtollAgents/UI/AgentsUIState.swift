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

// Local, view-only state of the Agents section. A tiny ObservableObject instead of `@State` (the SwiftUI macro plugin
// is not available to the command-line build) and so that lazily created rows do not own state that would be lost
// when they scroll out of view.

enum AgentsFocus: Hashable {
    case newTask(UUID)
    case renameSection(UUID)
    case newSection
    case editTaskTitle(UUID)
    case session(String)
}

enum AgentsDropTarget: Equatable {
    case section(UUID)
    case task(UUID)
}

struct AlwaysAllowRequest: Equatable {
    var approvalID: UUID
    var suggestion: PermissionSuggestion
}

@MainActor
final class AgentsUIState: ObservableObject {
    // Sessions / approvals
    @Published var dashboardTab: AgentsDashboardTab = .activity
    @Published var selectedUsageKind: AgentKind?
    @Published var usageWindowHours = 24
    @Published var expandedSessions: Set<String> = []
    @Published var expandedApprovals: Set<UUID> = []
    @Published var alwaysAllow: AlwaysAllowRequest?
    @Published var sessionsCollapsed = false
    @Published var boardCollapsed = false
    @Published var expandedSubagents: Set<String> = []
    @Published var hoveredRow: String?          // session id or task id under the pointer
    @Published var hiddenSessions: Set<String> = []     // "Hide from list" (view-only, resets on relaunch)
    @Published var dropTarget: AgentsDropTarget?
    @Published var draggingTask: UUID?

    // Feedback triggers (sensoryFeedback)
    @Published var approveTick = 0
    @Published var denyTick = 0
    @Published var attentionTick = 0

    // Board
    @Published var taskDrafts: [UUID: String] = [:]
    @Published var addingSection = false
    @Published var newSectionDraft = ""
    @Published var renamingSection: UUID?
    @Published var renameText = ""
    @Published var confirmDeleteSection: UUID?
    @Published var editingTask: UUID?
    @Published var editTitle = ""
    @Published var editNotes = ""

    // Transient toast mirroring `AgentCenter.lastNotice`
    @Published var toast: String?
    private var toastToken = 0

    // Codex trust hint dismissal survives relaunches (plain UserDefaults, not shared with anything else).
    private static let hintKey = "atollAgents.codexTrustHintDismissed"
    @Published var codexHintDismissed: Bool = UserDefaults.standard.bool(forKey: AgentsUIState.hintKey) {
        didSet { UserDefaults.standard.set(codexHintDismissed, forKey: AgentsUIState.hintKey) }
    }

    func toggleSession(_ id: String) {
        if expandedSessions.contains(id) { expandedSessions.remove(id) } else { expandedSessions.insert(id) }
    }

    func toggleApproval(_ id: UUID) {
        if expandedApprovals.contains(id) { expandedApprovals.remove(id) } else { expandedApprovals.insert(id) }
    }

    func draftBinding(for section: UUID) -> Binding<String> {
        Binding(get: { self.taskDrafts[section] ?? "" }, set: { self.taskDrafts[section] = $0 })
    }

    func showToast(_ text: String?, duration: TimeInterval = 3.5) {
        toastToken += 1
        toast = text
        guard text != nil else { return }
        let token = toastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.toast = nil
        }
    }

    /// Drops state that refers to things that no longer exist, so the sets cannot grow forever.
    func prune(sessionIDs: Set<String>, approvalIDs: Set<UUID>, sectionIDs: Set<UUID>) {
        if !expandedSessions.isSubset(of: sessionIDs) { expandedSessions.formIntersection(sessionIDs) }
        if !expandedSubagents.isSubset(of: sessionIDs) { expandedSubagents.formIntersection(sessionIDs) }
        if !expandedApprovals.isSubset(of: approvalIDs) { expandedApprovals.formIntersection(approvalIDs) }
        if let a = alwaysAllow, !approvalIDs.contains(a.approvalID) { alwaysAllow = nil }
        if let r = renamingSection, !sectionIDs.contains(r) { renamingSection = nil }
        if let c = confirmDeleteSection, !sectionIDs.contains(c) { confirmDeleteSection = nil }
        for key in taskDrafts.keys where !sectionIDs.contains(key) { taskDrafts[key] = nil }
    }
}
