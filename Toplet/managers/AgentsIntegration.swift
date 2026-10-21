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

import AppKit
import Combine
import Defaults
import Foundation
import os.log

// Glue between the standalone AI-agents module (managers/Agents/, components/Notch/Agents/, synced from AtollAgents/) and
// the rest of Atoll. Lives OUTSIDE those two folders on purpose: `local/sync-agents.sh` replaces everything inside them.
//
// While `enableAgentsFeature` is off NOTHING here runs: no socket, no discovery scan, no timer, no subscription besides the
// one Defaults observer that waits for the switch.

/// Counts and states only. Never a prompt, a command, a title, a path or a session id.
/// Read it with: /usr/bin/log show --last 5m --predicate 'subsystem == "app.toplet.Toplet" AND category == "agents"'
enum AgentsLog {
    static let log = OSLog(subsystem: "app.toplet.Toplet", category: "agents")
    static func note(_ message: String) {
        os_log("%{public}@", log: log, type: .default, message)
    }
}

extension Notification.Name {
    /// Posted (object: nil) to make the Settings window select the "AI Agents" page.
    static let atollOpenAIAgentsSettings = Notification.Name("com.ebullioscopic.Atoll.openAIAgentsSettings")
}

/// What the closed notch needs to know: the summary of active agents. Published only when the summary CHANGES, so the
/// (large) ContentView re-evaluates rarely, and never while the feature is off (the summary stays empty).
@MainActor
final class AgentsClosedModel: ObservableObject {
    static let shared = AgentsClosedModel()
    @Published private(set) var summary = AgentsClosedSummary()
    @Published var hourTokens = 0
    @Published var usageIndexing = true

    func set(_ new: AgentsClosedSummary) {
        if summary != new { summary = new }
    }
}

@MainActor
final class AgentsRuntime: ObservableObject {
    static let shared = AgentsRuntime()

    /// The live center. Replaced (stopped, rebuilt, started) when the approval timeout or passive discovery setting
    /// changes, because the core reads those once at start. Views observe the runtime so they follow the replacement.
    @Published private(set) var center: AgentCenter

    private let closed = AgentsClosedModel.shared
    private var configured = false
    private var defaultsCancellables = Set<AnyCancellable>()
    private var centerCancellables = Set<AnyCancellable>()
    private var restartWork: DispatchWorkItem?

    private var tabVisible = false
    private var fastPolling = false
    private var lastSessions: [AgentSession] = []
    private var lastPending: [PendingApproval] = []
    private var lastLine = ""
    private var knownStatus: [String: SessionStatus] = [:]
    private var knownPending = Set<UUID>()
    private var lastUnseen = 0
    private var serverErrored = false
    /// false until the socket had a moment to bind after start(); keeps the first log line truthful.
    private var settled = false

    private init() {
        center = AgentsRuntime.makeCenter()
    }

    // MARK: Settings -> center

    /// Clamp used everywhere (settings stepper, center config, log). The hook installer's blocking timeout is 900 s.
    static func clampedTimeout(_ seconds: Int) -> Int { min(max(seconds, 15), 600) }

    private static func makeCenter() -> AgentCenter {
        var config = AgentCenterConfig()
        config.approvalTimeout = TimeInterval(clampedTimeout(Defaults[.agentsApprovalTimeoutSeconds]))
        config.enableDiscovery = Defaults[.agentsPassiveDiscovery]
        let c = AgentCenter(config: config)
        c.hookInstaller = HookInstaller()
        return c
    }

    // MARK: Lifecycle

    /// Call once from applicationDidFinishLaunching. Starts the center only when the user enabled the feature.
    func configure() {
        guard !configured else { return }
        configured = true

        Defaults.publisher(.enableAgentsFeature, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                MainActor.assumeIsolated { self?.setEnabled(change.newValue) }
            }
            .store(in: &defaultsCancellables)

        // These only matter while the center runs; they cost nothing otherwise.
        Defaults.publisher(.agentsApprovalTimeoutSeconds, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRestart() } }
            .store(in: &defaultsCancellables)
        Defaults.publisher(.agentsPassiveDiscovery, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRestart() } }
            .store(in: &defaultsCancellables)
        Defaults.publisher(.agentsShowClosedIndicator, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshClosedSummary() } }
            .store(in: &defaultsCancellables)

        if Defaults[.enableAgentsFeature] { startCenter() }
    }

    private func setEnabled(_ on: Bool) {
        if on { startCenter() } else { stopCenter() }
    }

    private func startCenter() {
        guard !center.isRunning else { return }
        restartWork?.cancel(); restartWork = nil
        center = AgentsRuntime.makeCenter()
        resetLogState()
        bind(center)
        center.start()
        AgentsLog.note("start timeout=\(AgentsRuntime.clampedTimeout(Defaults[.agentsApprovalTimeoutSeconds])) passive=\(Defaults[.agentsPassiveDiscovery] ? "yes" : "no") indicator=\(Defaults[.agentsShowClosedIndicator] ? "yes" : "no")")
        // The socket is bound on the engine queue; report the real state a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.settled = true; self?.logState() }
        }
    }

    private func stopCenter() {
        restartWork?.cancel(); restartWork = nil
        let wasRunning = center.isRunning
        centerCancellables.removeAll()
        center.stop()
        closed.set(AgentsClosedSummary())
        fastPolling = false
        resetLogState()
        if wasRunning { AgentsLog.note("stop") }
        // The Agents tab disappears with the feature: never leave the notch showing a tab that no longer exists.
        let coordinator = DynamicIslandViewCoordinator.shared
        if coordinator.currentView == .agents { coordinator.currentView = .home }
    }

    /// applicationWillTerminate: releases the socket; approvals that are still pending fall back to the agent's own prompt.
    func shutdown() {
        guard center.isRunning else { return }
        centerCancellables.removeAll()
        center.stop()
        AgentsLog.note("stop reason=quit")
    }

    private func scheduleRestart() {
        guard center.isRunning else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restartNow() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func restartNow() {
        restartWork = nil
        guard center.isRunning else { return }
        AgentsLog.note("restart reason=settings")
        centerCancellables.removeAll()
        center.stop()
        center = AgentsRuntime.makeCenter()
        resetLogState()
        bind(center)
        center.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.settled = true; self?.logState() }
        }
    }

    // MARK: Observing the center

    private func bind(_ c: AgentCenter) {
        centerCancellables.removeAll()
        Publishers.CombineLatest(c.$sessions, c.$pending)
            .sink { [weak self] sessions, pending in
                MainActor.assumeIsolated { self?.apply(sessions: sessions, pending: pending) }
            }
            .store(in: &centerCancellables)
        c.$usageReport
            .sink { [weak self] report in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = Date()
                    let value = report.totals(since: now.addingTimeInterval(-3600), until: now).total
                    if self.closed.hourTokens != value { self.closed.hourTokens = value }
                    if self.closed.usageIndexing != report.indexing { self.closed.usageIndexing = report.indexing }
                }
            }
            .store(in: &centerCancellables)
        c.$unseenCompletionCount
            .sink { [weak self] count in
                MainActor.assumeIsolated { self?.unseenChanged(count) }
            }
            .store(in: &centerCancellables)
        c.$serverError
            .sink { [weak self] message in
                MainActor.assumeIsolated {
                    self?.serverErrored = (message?.isEmpty == false)
                    self?.logState()
                }
            }
            .store(in: &centerCancellables)
    }

    private func apply(sessions: [AgentSession], pending: [PendingApproval]) {
        lastSessions = sessions
        lastPending = pending
        refreshClosedSummary()
        logTransitions(sessions: sessions, pending: pending)
        logState()
    }

    private func refreshClosedSummary() {
        guard center.isRunning else { closed.set(AgentsClosedSummary()); return }
        let summary = Defaults[.agentsShowClosedIndicator]
            ? AgentsClosedSummary.make(sessions: lastSessions, pending: lastPending)
            : AgentsClosedSummary()
        closed.set(summary)
        updatePolling()
    }

    /// Fast (5 s) discovery only while something is looking: the Agents tab is open or the closed indicator is drawn.
    private func updatePolling() {
        let want = center.isRunning && (tabVisible || !closed.summary.isEmpty)
        guard want != fastPolling else { return }
        fastPolling = want
        center.setNeedsFastPolling(want)
    }

    func setTabVisible(_ visible: Bool) {
        guard tabVisible != visible else { return }
        tabVisible = visible
        updatePolling()
    }

    private func unseenChanged(_ count: Int) {
        defer { lastUnseen = count }
        guard count > lastUnseen, Defaults[.agentsNotifyOnFinish], !tabVisible else { return }
        NSSound(named: NSSound.Name("Glass"))?.play()
    }

    // MARK: Actions used by the notch views

    func openAgentsTab(openNotch: () -> Void) {
        DynamicIslandViewCoordinator.shared.currentView = .agents
        openNotch()
    }

    func openSettings() {
        SettingsWindowController.shared.showWindow()
        NotificationCenter.default.post(name: .atollOpenAIAgentsSettings, object: nil)
    }

    // MARK: Diagnostics (counts and states only)

    private func resetLogState() {
        lastSessions = []; lastPending = []; lastLine = ""
        knownStatus = [:]; knownPending = []; lastUnseen = 0; serverErrored = false; settled = false
    }

    private func socketIsListening() -> Bool {
        var st = stat()
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".atoll/run/agent.sock")
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
    }

    private func logState() {
        guard center.isRunning, settled else { return }
        let s = lastSessions
        let live = s.filter { $0.isLive }.count
        let claude = s.filter { $0.key.kind == .claudeCode }.count
        let codex = s.filter { $0.key.kind == .codex }.count
        let unseen = s.filter { $0.hasUnseenCompletion }.count
        let listening = !serverErrored && socketIsListening()
        let line = "sessions=\(s.count) live=\(live) passive=\(s.count - live) claude=\(claude) codex=\(codex) pending=\(lastPending.count) unseen=\(unseen) listening=\(listening ? "yes" : "no")"
        guard line != lastLine else { return }
        lastLine = line
        AgentsLog.note(line)
    }

    private func logTransitions(sessions: [AgentSession], pending: [PendingApproval]) {
        var current: [String: SessionStatus] = [:]
        for session in sessions {
            current[session.id] = session.status
            if knownStatus[session.id] != session.status {
                let origin = session.isLive ? "hook" : "passive"
                AgentsLog.note("session agent=\(session.key.kind.rawValue) status=\(session.status.rawValue) via=\(origin)")
            }
        }
        let gone = knownStatus.keys.filter { current[$0] == nil }.count
        if gone > 0 { AgentsLog.note("sessions-removed count=\(gone)") }
        knownStatus = current

        let ids = Set(pending.map(\.id))
        for approval in pending where !knownPending.contains(approval.id) {
            AgentsLog.note("event kind=PermissionRequest agent=\(approval.sessionKey.kind.rawValue)")
        }
        let closedCount = knownPending.subtracting(ids).count
        if closedCount > 0 { AgentsLog.note("approvals-closed count=\(closedCount)") }
        knownPending = ids
    }
}
