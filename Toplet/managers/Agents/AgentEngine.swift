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

import Foundation

/// Off-main orchestrator: owns the socket server, the discovery loop and the reducer state. Everything runs on one
/// serial queue; snapshots are coalesced to at most 10 per second and handed to `onSnapshot`. When stopped it holds
/// no sockets, timers, queues' work or file handles, so it costs nothing.
final class AgentEngine {
    struct Config {
        var socketPath: String?
        var approvalTimeout: TimeInterval = 90
        var limits = AgentSocketServer.Limits()
        var discovery = DiscoveryConfig()
        var discoveryInterval: TimeInterval = 15
        var discoveryMaxBackoff: TimeInterval = 60
        /// Cadence while the UI is looking (Agents tab open / indicator visible).
        var discoveryActiveInterval: TimeInterval = 5
        var passive = PassivePolicy.default
        var enableDiscovery = true
        var enableServer = true
        var publishInterval: TimeInterval = 0.1
        var expireInterval: TimeInterval = 20
        // Injection points (tests / preview)
        var processSource: ProcessSource?
        var appResolver: AppResolver?
        var tmuxResolver: ((String) -> JumpTarget?)?
        var clock: () -> Date = Date.init
        var pidAlive: ((Int32, Date?) -> Bool)?
        init() {}
    }

    let config: Config
    let queue = DispatchQueue(label: "atoll.agents.engine", qos: .userInitiated)
    private let specificKey = DispatchSpecificKey<UInt8>()

    /// Delivered on `queue`. The receiver must hop to its own isolation domain.
    var onSnapshot: (([AgentSession], [PendingApproval]) -> Void)?
    var onServerError: ((String?) -> Void)?

    private var state = ReducerState()
    private var pendingList: [PendingApproval] = []
    private var server: AgentSocketServer?
    private var loop: DiscoveryLoop?
    private var registry: DiscoveryRegistry?
    private var expireTimer: DispatchSourceTimer?
    private var running = false

    private var lastSessions: [AgentSession] = []
    private var lastPending: [PendingApproval] = []
    private var publishScheduled = false
    private var lastPublish: DispatchTime?
    private(set) var publishCount = 0
    private(set) var lastDiscoveryNotes: [String] = []

    init(config: Config = Config()) {
        self.config = config
        queue.setSpecific(key: specificKey, value: 1)
    }

    private func sync<T>(_ f: () -> T) -> T {
        if DispatchQueue.getSpecific(key: specificKey) != nil { return f() }
        return queue.sync(execute: f)
    }

    var socketPath: String? { sync { server?.socketPath } }
    var isRunning: Bool { sync { running } }
    var scanCount: Int { sync { loop?.scanCount ?? 0 } }
    var currentSessions: [AgentSession] { sync { SessionReducer.sorted(state) } }
    var currentPending: [PendingApproval] { sync { pendingList } }
    var serverStats: AgentSocketServer.Stats? { sync { server?.currentStats } }

    /// The hook installer gives PermissionRequest a 900 s backstop and requires the core's timeout to stay <= 600 s.
    static let maxApprovalTimeout: TimeInterval = 600
    static func clampedApprovalTimeout(_ t: TimeInterval) -> TimeInterval { min(max(t, 0.2), maxApprovalTimeout) }

    // MARK: Lifecycle

    func start() {
        sync {
            guard !running else { return }
            running = true
            if config.enableServer { startServer() }
            if config.enableDiscovery { startDiscovery() }
            startExpiry()
            markDirty()
        }
    }

    func stop() {
        sync {
            guard running else { return }
            running = false
            server?.broker.onChange = nil
            server?.onEvent = nil
            server?.stop()
            server = nil
            loop?.stop(); loop = nil; registry = nil
            expireTimer?.cancel(); expireTimer = nil
            state = ReducerState(); pendingList = []; lastSessions = []; lastPending = []
            publishScheduled = false
            onSnapshot = nil
        }
        queue.sync {}   // let queued blocks (publish, discovery deliveries) run out
    }

    private func startServer() {
        var limits = config.limits
        limits.approvalTimeout = AgentEngine.clampedApprovalTimeout(config.approvalTimeout)
        let s = AgentSocketServer(socketPath: config.socketPath, limits: limits, queue: queue)
        s.onEvent = { [weak self] ev in self?.ingest(ev) }
        s.broker.onChange = { [weak self] ch in self?.brokerChanged(ch) }
        do {
            try s.start()
            server = s
            onServerError?(nil)
        } catch {
            server = nil
            onServerError?((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func startDiscovery() {
        let registry = DiscoveryRegistry(config: config.discovery, source: config.processSource ?? LibprocSource(),
                                         apps: config.appResolver ?? PlistAppResolver(), now: config.clock)
        if let t = config.tmuxResolver { registry.tmuxResolver = t }
        registry.policy = config.passive
        self.registry = registry
        let l = DiscoveryLoop(interval: config.discoveryInterval, maxBackoff: config.discoveryMaxBackoff, activeInterval: config.discoveryActiveInterval,
                              scan: { registry.scan() },
                              deliver: { [weak self] result in self?.queue.async { self?.ingestDiscovery(result) } })
        loop = l
        l.start()
    }

    private func startExpiry() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + config.expireInterval, repeating: config.expireInterval, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.runExpiry() }
        expireTimer = t
        t.resume()
    }

    /// The UI is (not) looking at agent state: 5 s scans while it is, 15-60 s otherwise. Stopped engine: nothing runs.
    func setFastPolling(_ on: Bool) { sync { loop?.setActive(on) } }

    // MARK: Acknowledging completions

    func acknowledge(_ key: SessionKey) { sync { guard running else { return }; SessionReducer.acknowledge(&state, key: key); markDirty() } }
    func acknowledgeAll() { sync { guard running else { return }; SessionReducer.acknowledge(&state, key: nil); markDirty() } }
    func acknowledge(hostBundleID: String) { sync { guard running else { return }; SessionReducer.acknowledge(&state, hostBundleID: hostBundleID); markDirty() } }

    func refreshDiscovery() { sync { registry?.requestOnDemandCLI(); loop?.refreshNow() } }

    // MARK: Ingest (all on `queue`)

    func ingest(_ ev: AgentEvent) {
        sync {
            guard running else { return }
            cancelStalePending(for: ev)
            SessionReducer.apply(ev, to: &state, now: config.clock())
            markDirty()
        }
    }

    /// The session moved on: approvals that can no longer be answered are closed with no reply.
    private func cancelStalePending(for ev: AgentEvent) {
        guard let server = server else { return }
        let key = ev.key
        switch ev.payload {
        case .promptSubmit, .stop, .stopFailure, .sessionEnd, .interrupt, .permissionDenied, .turnStarted, .turnCompleted, .turnAborted, .shutdown:
            server.broker.cancel(session: key)
        case .toolEnd(let info, _):
            // Only the approval for the tool that just finished (parallel tools may have other approvals pending).
            for p in pendingList where p.sessionKey == key && p.tool == info.name && (info.summary.isEmpty || p.summary == info.summary) {
                server.broker.abort(p.id, reason: .cancelled)
            }
        default:
            break
        }
    }

    private func brokerChanged(_ change: ApprovalBroker.Change) {
        switch change {
        case .added(let a):
            pendingList.append(a)
        case .removed(let id, let key, let closure):
            pendingList.removeAll { $0.id == id }
            var allowed: Bool?
            switch closure {
            case .allowed, .allowedAlways: allowed = true
            case .denied: allowed = false
            default: allowed = nil
            }
            let ev = AgentEvent(kind: key.kind, sessionID: key.id, payload: .approvalResolved(allowed: allowed), provenance: .hook)
            SessionReducer.apply(ev, to: &state, now: config.clock())
        }
        markDirty()
    }

    func decide(_ id: UUID, _ decision: ApprovalDecision) {
        sync { server?.decide(id, decision) }
    }

    func ingestDiscovery(_ result: DiscoveryResult) {
        sync {
            guard running else { return }
            let now = config.clock()
            SessionReducer.apply(discovered: result.sessions, complete: result.complete, policy: config.passive, to: &state, now: now)
            lastDiscoveryNotes = result.notes
            runExpiry()
        }
    }

    func runExpiry() {
        sync {
            guard running else { return }
            let alive = config.pidAlive ?? { pid, start in ProcessLiveness.isAlive(pid: pid, expectedStart: start) }
            SessionReducer.expire(&state, now: config.clock(), policy: config.passive, isPidAlive: alive)
            markDirty()
        }
    }

    // MARK: Publishing (<= 10 Hz)

    private func markDirty() {
        guard running, !publishScheduled else { return }
        publishScheduled = true
        var delay: TimeInterval = 0
        if let last = lastPublish {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds) / 1e9
            delay = max(0, config.publishInterval - elapsed)
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.publish() }
    }

    private func publish() {
        publishScheduled = false
        guard running else { return }
        lastPublish = .now()
        let sessions = SessionReducer.sorted(state)
        let pending = pendingList
        if sessions == lastSessions && pending == lastPending && publishCount > 0 { return }
        lastSessions = sessions; lastPending = pending
        publishCount += 1
        onSnapshot?(sessions, pending)
    }
}
