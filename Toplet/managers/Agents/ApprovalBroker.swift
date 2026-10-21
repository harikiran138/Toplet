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

/// The other end of a pending approval (an open hook connection). `finish` is called at most once.
protocol ApprovalResponder: AnyObject {
    /// Writes `data` (when non-nil and non-empty) and closes. nil = close without writing anything.
    func finish(writing data: Data?)
}

/// Holds pending permission approvals. Thread-safe: every mutation runs on the queue it was created with (the socket
/// server's queue); the public entry points hop onto it. Ids are server-generated UUIDs bound to ONE connection:
/// there is no way to answer except `decide(id, ...)`, and the reply bytes are built here from the enum, never from
/// client text.
final class ApprovalBroker {
    enum Closure: Equatable, Sendable {
        case allowed, allowedAlways, denied
        case terminal             // user chose "let the terminal decide"
        case timedOut
        case serverStopped
        case clientDisconnected
        case cancelled            // the session moved on (new prompt, stop, tool finished)
        case invalid              // decision could not be honoured (bad suggestion index, unsupported); terminal decides
    }

    enum Change: Sendable {
        case added(PendingApproval)
        case removed(UUID, SessionKey, Closure)
    }

    private struct Entry {
        var approval: PendingApproval
        var kind: AgentKind
        var entries: [Data]
        var responder: ApprovalResponder
        var timer: DispatchSourceTimer?
    }

    private let queue: DispatchQueue
    private let specificKey = DispatchSpecificKey<UInt8>()
    private var items: [UUID: Entry] = [:]
    private var order: [UUID] = []
    let maxPending: Int
    let timeout: TimeInterval
    private let now: () -> Date

    /// Called on the broker queue for every add/remove.
    var onChange: ((Change) -> Void)?

    init(queue: DispatchQueue, maxPending: Int = 16, timeout: TimeInterval = 90, now: @escaping () -> Date = Date.init) {
        self.queue = queue; self.maxPending = maxPending; self.timeout = timeout; self.now = now
        queue.setSpecific(key: specificKey, value: 1)
    }

    private func onQueue(_ f: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: specificKey) != nil { f() } else { queue.async(execute: f) }
    }

    var count: Int {
        if DispatchQueue.getSpecific(key: specificKey) != nil { return items.count }
        return queue.sync { items.count }
    }

    var pendingIDs: [UUID] {
        let f = { self.order }
        if DispatchQueue.getSpecific(key: specificKey) != nil { return f() }
        return queue.sync(execute: f)
    }

    // MARK: Add

    /// Registers a pending approval. nil when the cap is reached (the caller must then close the connection with no reply
    /// so the agent falls back to its own prompt).
    func add(sessionKey: SessionKey, kind: AgentKind, agentID: String?, info: PermissionInfo, responder: ApprovalResponder) -> PendingApproval? {
        let work: () -> PendingApproval? = { [self] in
            guard self.items.count < self.maxPending else { return nil }
            let created = self.now()
            let approval = PendingApproval(id: UUID(), sessionKey: sessionKey, agentID: agentID, tool: info.tool.name,
                                           summary: info.tool.summary, detail: info.tool.detail,
                                           suggestions: info.suggestions, createdAt: created,
                                           expiresAt: created.addingTimeInterval(self.timeout))
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.timeout, leeway: .milliseconds(50))
            let id = approval.id
            timer.setEventHandler { [weak self] in self?.finish(id, reason: .timedOut, reply: nil) }
            timer.resume()
            self.items[id] = Entry(approval: approval, kind: kind, entries: info.suggestionEntries, responder: responder, timer: timer)
            self.order.append(id)
            self.onChange?(.added(approval))
            return approval
        }
        if DispatchQueue.getSpecific(key: specificKey) != nil { return work() }
        return queue.sync(execute: work)
    }

    // MARK: Decide / close

    /// Answers `id` on its own connection. Unknown ids are ignored (already answered, timed out or disconnected).
    func decide(_ id: UUID, _ decision: ApprovalDecision) {
        onQueue { [weak self] in
            guard let self = self, let e = self.items[id] else { return }
            let reply = ApprovalBroker.decisionJSON(kind: e.kind, decision: decision, entries: e.entries)
            let reason: Closure
            switch decision {
            case .allowOnce: reason = reply == nil ? .invalid : .allowed
            case .allowAlways: reason = reply == nil ? .invalid : .allowedAlways
            case .deny: reason = reply == nil ? .invalid : .denied
            case .letTerminalDecide: reason = .terminal
            }
            self.finish(id, reason: reason, reply: reply)
        }
    }

    /// Closes without any reply (agent falls back to its own prompt).
    func abort(_ id: UUID, reason: Closure) {
        onQueue { [weak self] in self?.finish(id, reason: reason, reply: nil) }
    }

    /// Drops every pending approval of a session (the session moved on). No reply is written.
    func cancel(session: SessionKey, reason: Closure = .cancelled) {
        onQueue { [weak self] in
            guard let self = self else { return }
            for id in self.order where self.items[id]?.approval.sessionKey == session { self.finish(id, reason: reason, reply: nil) }
        }
    }

    func cancelAll(reason: Closure) {
        let work = { [self] in
            for id in order { finish(id, reason: reason, reply: nil) }
        }
        if DispatchQueue.getSpecific(key: specificKey) != nil { work() } else { queue.sync(execute: work) }
    }

    private func finish(_ id: UUID, reason: Closure, reply: Data?) {
        guard let e = items.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        e.timer?.cancel()
        e.responder.finish(writing: reply)
        onChange?(.removed(id, e.approval.sessionKey, reason))
    }

    // MARK: Decision JSON (server-side, from the enum)

    /// Builds the hook reply. nil = write nothing (terminal decides). Claude: hookSpecificOutput.decision allow/deny
    /// (+message for deny, +updatedPermissions only for allowAlways from the agent's own sanitised suggestion entry).
    /// Codex: allow/deny only.
    static func decisionJSON(kind: AgentKind, decision: ApprovalDecision, entries: [Data]) -> Data? {
        var d: [String: Any]
        switch decision {
        case .letTerminalDecide:
            return nil
        case .allowOnce:
            d = ["behavior": "allow"]
        case .deny(let message):
            d = ["behavior": "deny"]
            let m = AgentText.cleanOptional(message, max: 500) ?? "The user denied this request in Toplet."
            d["message"] = m
        case .allowAlways(let idx):
            // Codex's PermissionRequest hook fails closed on updatedPermissions: not supported there.
            guard kind == .claudeCode, idx >= 0, idx < entries.count, !entries[idx].isEmpty,
                  let entry = try? JSONSerialization.jsonObject(with: entries[idx]) as? [String: Any] else { return nil }
            d = ["behavior": "allow", "updatedPermissions": [entry]]
        }
        let root: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
