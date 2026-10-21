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

// Pure, deterministic state machine: AgentEvent / DiscoveredSession -> [SessionKey: AgentSession].
// Implements docs/AI-AGENTS-RESEARCH.md 6.1 and 6.2. No clocks, no I/O: the caller injects `now`.
//
// Conventions on AgentSession.waitingFor (display text, shown next to the status):
//   needsPermission -> "permission prompt" ; waitingInput -> "input needed" ; failed -> the error ("rate_limit");
//   running -> "compacting" while a compaction runs ; idle -> "interrupted" after a Codex interrupt / aborted turn.

enum ReducerLimits {
    static let maxSessions = 64
    static let maxTasks = 200
    static let maxSubagents = 32
    static let runningExpiry: TimeInterval = 10 * 60      // running -> unknown without events and without a known pid
    static let endedRetention: TimeInterval = 5 * 60      // done/stopped sessions are dropped after this
    static let deadPidGrace: TimeInterval = 15            // do not mark done the instant a pid disappears
    static let staleOverride: TimeInterval = 90           // a weaker source may overwrite a field the stronger one has not touched for this long
    static let unknownRetention: TimeInterval = 3600
    static let passiveIdleRetention: TimeInterval = 6 * 3600
}

enum SessionField: Hashable {
    case status, title, name, cwd, pid, host, tool, tasks, prompt, assistant, usage, model, transcript, mode
}

struct FieldStamp: Equatable { var prov: Provenance; var at: Date }

struct SessionMeta: Equatable {
    var field: [SessionField: FieldStamp] = [:]
    var endedAt: Date?
    var permissionTool: String?
    var permissionSummary: String?
    var hookSeen = false
    var lastSeenByDiscovery: Date?
    var lastDenial: String?
    /// Consecutive complete scans in which a passive session was missing.
    var missCount = 0
    var unseenSince: Date?
    /// Subagent thread -> parent session (Codex `parent_thread_id`). Children are hidden under their parent when it exists.
    var parent: SessionKey?
}

struct ReducerState: Equatable {
    var sessions: [SessionKey: AgentSession] = [:]
    var meta: [SessionKey: SessionMeta] = [:]
    init() {}
}

enum SessionReducer {

    // MARK: Events

    static func apply(_ e: AgentEvent, to st: inout ReducerState, now: Date) {
        var t = e.at ?? now
        if t > now.addingTimeInterval(5) { t = now }

        // Session ends never create sessions.
        if case .sessionEnd = e.payload, st.sessions[e.key] == nil, resolveRekey(e, &st) == nil { return }

        var key = e.key
        if st.sessions[key] == nil, let moved = resolveRekey(e, &st) { key = moved }
        if st.sessions[key] == nil {
            makeRoom(&st, protecting: key)
            var s = AgentSession(key: key, cwd: e.cwd ?? "", projectName: nil, status: .unknown, now: t)
            s.projectName = projectName(for: e.cwd ?? "")
            st.sessions[key] = s
            st.meta[key] = SessionMeta()
            // First sight: an event stream means the session is at least idle/running, not "unknown".
            st.sessions[key]!.status = .idle
        }

        var ed = Editor(s: st.sessions[key]!, m: st.meta[key] ?? SessionMeta(), now: now)
        ed.applyCommon(e, t: t)
        ed.applyPayload(e, t: t)
        ed.s.lastEventAt = max(ed.s.lastEventAt, t)
        st.sessions[key] = ed.s
        st.meta[key] = ed.m
    }

    /// Moves a synthetic "pid:N" session (created by the process scan) to the real id once a hook/registry event names it.
    private static func resolveRekey(_ e: AgentEvent, _ st: inout ReducerState) -> SessionKey? {
        guard let pid = e.pid, pid > 1, !e.sessionID.hasPrefix("pid:") else { return nil }
        guard let synth = st.sessions.first(where: { $0.key.kind == e.kind && $0.key.id.hasPrefix("pid:") && $0.value.pid == pid })?.key else { return nil }
        return rekey(&st, from: synth, to: e.key)
    }

    @discardableResult
    static func rekey(_ st: inout ReducerState, from old: SessionKey, to new: SessionKey) -> SessionKey? {
        guard old != new, var s = st.sessions.removeValue(forKey: old) else { return nil }
        s.key = new
        if let existing = st.sessions[new] {
            // The real session already exists (e.g. both seen): keep the richer one and drop the synthetic.
            st.sessions[new] = existing.provenance >= s.provenance ? existing : s
            st.meta.removeValue(forKey: old)
            return new
        }
        st.sessions[new] = s
        st.meta[new] = st.meta.removeValue(forKey: old) ?? SessionMeta()
        return new
    }

    static func projectName(for cwd: String) -> String {
        if cwd.isEmpty { return "" }
        let trimmed = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let last = (trimmed as NSString).lastPathComponent
        return AgentText.clean(last.isEmpty ? trimmed : last, max: 80)
    }

    // MARK: Bounds

    /// Evicts until there is room for one more session. Order: ended, then passive non-attention, then oldest.
    static func makeRoom(_ st: inout ReducerState, protecting: SessionKey) {
        while st.sessions.count >= ReducerLimits.maxSessions {
            let candidates = st.sessions.values.filter { $0.key != protecting }
            guard !candidates.isEmpty else { return }
            func rank(_ s: AgentSession) -> Int {
                if s.status == .done || s.status == .stopped { return 0 }
                if s.status == .unknown { return 1 }
                if !s.status.needsAttention && !s.isLive { return 2 }
                if !s.status.needsAttention { return 3 }
                return 4
            }
            let victim = candidates.min { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                if a.lastEventAt != b.lastEventAt { return a.lastEventAt < b.lastEventAt }
                return a.id < b.id
            }!
            st.sessions.removeValue(forKey: victim.key)
            st.meta.removeValue(forKey: victim.key)
        }
    }

    // MARK: Expiry

    static func expire(_ st: inout ReducerState, now: Date, policy: PassivePolicy = .default, isPidAlive: (Int32, Date?) -> Bool) {
        for key in Array(st.sessions.keys).sorted(by: { $0.id < $1.id }) {
            guard var s = st.sessions[key] else { continue }
            var m = st.meta[key] ?? SessionMeta()

            // A completion flag is never kept forever.
            if s.hasUnseenCompletion, let u = m.unseenSince, now.timeIntervalSince(u) > policy.unseenMax {
                s.hasUnseenCompletion = false; m.unseenSince = nil
                st.sessions[key] = s; st.meta[key] = m
            }

            if s.status == .done || s.status == .stopped {
                let ended = m.endedAt ?? s.statusSince
                if m.endedAt == nil { m.endedAt = ended }
                if now.timeIntervalSince(ended) > ReducerLimits.endedRetention {
                    st.sessions.removeValue(forKey: key); st.meta.removeValue(forKey: key)
                } else { st.meta[key] = m }
                continue
            }

            if let pid = s.pid, !isPidAlive(pid, s.processStart) {
                if now.timeIntervalSince(s.lastEventAt) > ReducerLimits.deadPidGrace {
                    Editor.markEnded(&s, &m, now: now)
                    st.sessions[key] = s; st.meta[key] = m
                }
                continue
            }

            if s.pid == nil, s.status == .running || s.status == .starting,
               now.timeIntervalSince(s.lastEventAt) > ReducerLimits.runningExpiry {
                s.status = .unknown; s.statusSince = now; s.currentTool = nil; s.waitingFor = nil
                st.sessions[key] = s; st.meta[key] = m
                continue
            }

            if s.status == .unknown, now.timeIntervalSince(s.lastEventAt) > ReducerLimits.unknownRetention {
                st.sessions.removeValue(forKey: key); st.meta.removeValue(forKey: key)
                continue
            }
            if !s.isLive, !m.hookSeen, !s.status.needsAttention, s.status != .running,
               now.timeIntervalSince(s.lastEventAt) > policy.idleDrop {
                st.sessions.removeValue(forKey: key); st.meta.removeValue(forKey: key)
            }
        }
    }

    // MARK: Ordering

    /// needsPermission/waitingInput/failed first, then lastEventAt descending; id breaks ties so the order is stable.
    static func sorted(_ st: ReducerState) -> [AgentSession] {
        st.sessions.values.filter { s in
            // A subagent thread is shown under its parent (parent.subagents), not as a session of its own.
            guard let p = st.meta[s.key]?.parent else { return true }
            return st.sessions[p] == nil
        }.sorted { a, b in
            let aa = a.status.needsAttention, ab = b.status.needsAttention
            if aa != ab { return aa }
            if a.lastEventAt != b.lastEventAt { return a.lastEventAt > b.lastEventAt }
            return a.id < b.id
        }
    }

    // MARK: Acknowledging completions

    /// Clears "finished since you last looked" for one session (nil = all sessions).
    static func acknowledge(_ st: inout ReducerState, key: SessionKey?) {
        for k in st.sessions.keys where key == nil || k == key {
            st.sessions[k]!.hasUnseenCompletion = false
            st.meta[k]?.unseenSince = nil
        }
    }

    /// The user brought `bundleID` to the front: everything hosted there has been seen.
    static func acknowledge(_ st: inout ReducerState, hostBundleID: String) {
        for (k, s) in st.sessions where s.hostAppBundleID == hostBundleID && s.hasUnseenCompletion {
            st.sessions[k]!.hasUnseenCompletion = false
            st.meta[k]?.unseenSince = nil
        }
    }

    // MARK: Tasks

    static func applyMutation(_ m: TaskMutation, to tasks: inout [AgentTask]) {
        switch m {
        case .replaceAll(let list):
            tasks = Array(list.prefix(ReducerLimits.maxTasks))
        case .create(let t):
            create(t, in: &tasks)
        case .update(let id, let status, let title, let active):
            if let i = tasks.firstIndex(where: { $0.id == id }) {
                if let s = status { tasks[i].status = s }
                if let tt = title { tasks[i].title = tt }
                if let a = active { tasks[i].activeForm = a }
            } else if title != nil || status != nil {
                create(AgentTask(id: id, title: title ?? "Task #\(id)", status: status ?? .pending, activeForm: active), in: &tasks)
            }
        case .delete(let id):
            tasks.removeAll { $0.id == id }
        }
        for i in tasks.indices { tasks[i].order = i }
    }

    private static func create(_ t: AgentTask, in tasks: inout [AgentTask]) {
        if !t.id.isEmpty, let i = tasks.firstIndex(where: { $0.id == t.id }) {
            tasks[i].title = t.title
            if let a = t.activeForm { tasks[i].activeForm = a }
            return
        }
        if let i = tasks.firstIndex(where: { $0.status == .pending && $0.title.caseInsensitiveCompare(t.title) == .orderedSame }) {
            if !t.id.isEmpty { tasks[i].id = t.id }
            return
        }
        guard tasks.count < ReducerLimits.maxTasks else { return }
        var n = t
        if n.id.isEmpty {
            let maxNum = tasks.compactMap { Int($0.id) }.max() ?? 0
            n.id = String(max(maxNum, tasks.count) + 1)
        }
        n.order = tasks.count
        tasks.append(n)
    }

    // MARK: Editor (one session + its meta)

    struct Editor {
        var s: AgentSession
        var m: SessionMeta
        let now: Date

        init(s: AgentSession, m: SessionMeta, now: Date) { self.s = s; self.m = m; self.now = now }

        static func markEnded(_ s: inout AgentSession, _ m: inout SessionMeta, now: Date) {
            if s.status == .running { s.hasUnseenCompletion = true; m.unseenSince = now }
            s.statusDetail = nil
            s.status = .done; s.statusSince = now; s.currentTool = nil; s.waitingFor = nil
            for i in s.subagents.indices where [.running, .idle, .waiting].contains(s.subagents[i].status) { s.subagents[i].status = .done; s.subagents[i].currentTool = nil }
            m.endedAt = now
            m.permissionTool = nil; m.permissionSummary = nil
        }

        func allowed(_ f: SessionField, _ prov: Provenance) -> Bool {
            guard let st = m.field[f] else { return true }
            return prov >= st.prov || now.timeIntervalSince(st.at) > ReducerLimits.staleOverride
        }

        mutating func stamp(_ f: SessionField, _ prov: Provenance, _ t: Date) {
            m.field[f] = FieldStamp(prov: prov, at: t)
        }

        @discardableResult
        mutating func setStatus(_ new: SessionStatus, waitingFor: String? = nil, detail: String? = nil, prov: Provenance, t: Date) -> Bool {
            guard allowed(.status, prov) else { return false }
            // "Finished since you last looked": a turn ended (running -> idle/done). An interrupt is the user's own doing.
            if s.status == .running, new == .idle || new == .done, waitingFor != "interrupted" {
                s.hasUnseenCompletion = true; m.unseenSince = t
            }
            if new == .running { s.hasUnseenCompletion = false; m.unseenSince = nil }
            s.statusDetail = detail
            if s.status != new { s.statusSince = t }
            s.status = new
            s.waitingFor = waitingFor
            if new != .done && new != .stopped { m.endedAt = nil }
            stamp(.status, prov, t)
            return true
        }

        mutating func setText(_ f: SessionField, _ prov: Provenance, _ t: Date, _ value: String?, into kp: WritableKeyPath<AgentSession, String?>) {
            guard let v = value, !v.isEmpty, allowed(f, prov) else { return }
            s[keyPath: kp] = v
            stamp(f, prov, t)
        }

        mutating func applyCommon(_ e: AgentEvent, t: Date) {
            let prov = e.provenance
            if let c = e.cwd, !c.isEmpty, allowed(.cwd, prov) {
                s.cwd = c; s.projectName = SessionReducer.projectName(for: c); stamp(.cwd, prov, t)
            }
            if let p = e.transcriptPath, !p.isEmpty, allowed(.transcript, prov) { s.transcriptPath = p; stamp(.transcript, prov, t) }
            if let p = e.permissionMode, !p.isEmpty, allowed(.mode, prov) { s.permissionMode = p; stamp(.mode, prov, t) }
            if let mo = e.model, !mo.isEmpty, allowed(.model, prov) { s.model = mo; stamp(.model, prov, t) }
            if prov == .hook {
                s.isLive = true
                m.hookSeen = true
                if let pid = e.pid, pid > 1, (s.pid == nil || allowed(.pid, .hook)) {
                    if s.pid != pid { s.processStart = nil }   // new pid: the old start time no longer applies
                    s.pid = pid; stamp(.pid, .hook, t)
                }
            }
            if prov > s.provenance { s.provenance = prov }
        }

        // MARK: Per payload

        mutating func applyPayload(_ e: AgentEvent, t: Date) {
            let prov = e.provenance
            switch e.payload {

            case .sessionStart(let source, let title):
                setText(.title, prov, t, title, into: \.title)
                let src = source ?? "startup"
                let wasEnded = s.status == .done || s.status == .stopped
                if src == "startup" || src == "clear" || wasEnded || s.status == .unknown {
                    if src == "startup" || src == "clear" {
                        s.tasks = []; s.currentTool = nil
                        for i in s.subagents.indices where [.running, .idle, .waiting].contains(s.subagents[i].status) { s.subagents[i].status = .done }
                    }
                    setStatus(.idle, prov: prov, t: t)
                }
                m.endedAt = nil

            case .sessionEnd:
                Editor.markEnded(&s, &m, now: t)
                stamp(.status, prov, t)

            case .promptSubmit(let prompt, let title):
                if let prompt, AgentText.userFacingPrompt(prompt) == nil { break }
                if let p = prompt { setText(.prompt, prov, t, p, into: \.lastPrompt) }
                setText(.title, prov, t, title, into: \.title)
                // The title is the USER's latest prompt (not the agent's chatter); an explicit title (hook session_title,
                // ai-title, /rename) is stronger and is left alone.
                if let p = prompt, allowed(.title, .processScan) { s.title = AgentText.clean(p, max: 80); stamp(.title, .processScan, t) }
                s.hasUnseenCompletion = false; m.unseenSince = nil
                // A new prompt always starts a new turn: it clears sticky failure and stale permission state.
                setStatus(.running, prov: prov, t: t)
                clearTool(prov, t)
                m.permissionTool = nil; m.permissionSummary = nil

            case .lastPrompt(let p):
                setText(.prompt, prov, t, p, into: \.lastPrompt)

            case .toolStart(let info):
                if let id = e.agentID { updateSubagentTool(id: id, type: e.agentType, tool: activity(info, t), t: t) }
                else if allowed(.tool, prov) {
                    s.currentTool = activity(info, t); stamp(.tool, prov, t)
                }
                applyTaskMutation(info.taskMutation, onStart: true, prov: prov, t: t)
                if s.status == .failed && prov == .hook { break }                       // sticky until the next prompt
                if s.status == .needsPermission && prov == .hook && m.permissionTool == info.name { break }   // hooks race: Pre may arrive after Permission
                if s.status == .done || s.status == .stopped { if prov == .hook { break } }
                setStatus(.running, prov: prov, t: t)

            case .toolEnd(let info, let failed):
                if let id = e.agentID { clearSubagentTool(id: id, toolUseID: info.toolUseID) }
                else if let cur = s.currentTool, info.toolUseID == nil || cur.toolUseID == nil || cur.toolUseID == info.toolUseID {
                    clearTool(prov, t)
                }
                if !failed { applyTaskMutation(info.taskMutation, onStart: false, prov: prov, t: t) }
                if info.isSubagentTool, let sid = info.spawnedAgentID, let i = s.subagents.firstIndex(where: { $0.id == sid }) {
                    s.subagents[i].status = failed ? .failed : .done; s.subagents[i].currentTool = nil
                }
                if s.status == .needsPermission && (m.permissionTool == nil || m.permissionTool == info.name || info.name == "tool" || prov != .hook) {
                    // The tool ran (or failed after approval): the permission question is over.
                    m.permissionTool = nil; m.permissionSummary = nil
                    setStatus(.running, prov: prov, t: t)
                }

            case .permissionRequest(let info):
                if setStatus(.needsPermission, waitingFor: "permission prompt", prov: prov, t: t) || s.status == .needsPermission {
                    m.permissionTool = info.tool.name; m.permissionSummary = info.tool.summary
                }
                if e.agentID == nil, s.currentTool == nil { s.currentTool = activity(info.tool, t) }
                if let id = e.agentID { updateSubagentTool(id: id, type: e.agentType, tool: nil, t: t) }

            case .permissionDenied(let tool, _):
                m.lastDenial = tool
                m.permissionTool = nil; m.permissionSummary = nil
                if s.status == .needsPermission || s.status == .waitingInput { setStatus(.running, prov: prov, t: t) }

            case .approvalResolved(let allowed):
                m.permissionTool = nil; m.permissionSummary = nil
                // allowed/denied in Atoll: the agent proceeds. nil (terminal / timeout / EOF): the terminal still asks, keep the state.
                if allowed != nil, s.status == .needsPermission { setStatus(.running, prov: prov, t: t) }

            case .notification(let kind, _, _):
                switch kind {
                case .idlePrompt, .agentNeedsInput, .elicitation:
                    if s.status == .idle || s.status == .running || s.status == .unknown || s.status == .starting {
                        setStatus(.waitingInput, waitingFor: "input needed", prov: prov, t: t)
                    }
                case .agentCompleted:
                    if s.status == .running { setStatus(.idle, prov: prov, t: t) }
                case .permissionPrompt, .authSuccess, .other:
                    break   // permission_prompt is covered by PermissionRequest (research 6.1)
                }

            case .stop(let last):
                setText(.assistant, prov, t, last, into: \.lastAssistantText)
                if s.status != .done && s.status != .stopped {
                    setStatus(.idle, prov: prov, t: t)
                }
                clearTool(prov, t)
                m.permissionTool = nil; m.permissionSummary = nil

            case .stopFailure(let err):
                setStatus(.failed, waitingFor: err ?? "error", prov: prov, t: t)
                clearTool(prov, t)

            case .interrupt:
                setStatus(.idle, waitingFor: "interrupted", prov: prov, t: t)
                clearTool(prov, t)
                m.permissionTool = nil; m.permissionSummary = nil

            case .subagentIdle(let id, let type):
                upsertSubagent(id: id, type: type, t: t, status: .idle)

            case .subagentStart(let id, let type):
                upsertSubagent(id: id, type: type, t: t, status: .running)

            case .subagentStop(let id, let type, let last, let failed):
                upsertSubagent(id: id, type: type, t: t, status: failed ? .failed : .done)
                if let i = s.subagents.firstIndex(where: { $0.id == id }) {
                    s.subagents[i].currentTool = nil
                    if let l = last { s.subagents[i].lastText = l }
                }

            case .taskCreated(let id, let subject, _):
                var tasks = s.tasks
                SessionReducer.applyMutation(.create(AgentTask(id: id, title: subject, status: .pending)), to: &tasks)
                s.tasks = tasks; stamp(.tasks, prov, t)

            case .taskCompleted(let id, let subject):
                var tasks = s.tasks
                SessionReducer.applyMutation(.update(id: id, status: .completed, title: subject, activeForm: nil), to: &tasks)
                s.tasks = tasks; stamp(.tasks, prov, t)

            case .compact(let isStart, _):
                if isStart {
                    if s.status == .idle || s.status == .unknown { setStatus(.running, waitingFor: "compacting", prov: prov, t: t) }
                    else if s.status == .running { s.waitingFor = "compacting" }
                } else if s.waitingFor == "compacting" { s.waitingFor = nil }

            case .planUpdate(let tasks):
                if allowed(.tasks, prov) {
                    s.tasks = Array(tasks.prefix(ReducerLimits.maxTasks)); stamp(.tasks, prov, t)
                }

            case .turnStarted:
                if s.status == .done || s.status == .stopped, prov < .hook { break }
                m.permissionTool = nil; m.permissionSummary = nil
                setStatus(.running, prov: prov, t: t)

            case .turnCompleted(let last):
                setText(.assistant, prov, t, last, into: \.lastAssistantText)
                if s.status != .done && s.status != .stopped { setStatus(.idle, prov: prov, t: t) }
                clearTool(prov, t)

            case .turnAborted:
                if s.status != .done && s.status != .stopped { setStatus(.idle, waitingFor: "interrupted", prov: prov, t: t) }
                clearTool(prov, t)

            case .shutdown:
                Editor.markEnded(&s, &m, now: t)
                stamp(.status, prov, t)

            case .approvalNeeded(let waitingFor):
                if s.status != .done && s.status != .stopped {
                    let st: SessionStatus = (waitingFor ?? "permission prompt") == "permission prompt" ? .needsPermission : .waitingInput
                    setStatus(st, waitingFor: waitingFor ?? "permission prompt", prov: prov, t: t)
                }

            case .usage(let u):
                if allowed(.usage, prov) {
                    var cur = s.usage ?? UsageSnapshot(source: u.source)
                    if let v = u.costUSD { cur.costUSD = v }
                    if let v = u.contextUsedPercent { cur.contextUsedPercent = v }
                    if let v = u.fiveHourPercent { cur.fiveHourPercent = v }
                    if let v = u.sevenDayPercent { cur.sevenDayPercent = v }
                    cur.source = u.source
                    s.usage = cur; stamp(.usage, prov, t)
                }

            case .assistantText(let txt):
                setText(.assistant, prov, t, txt, into: \.lastAssistantText)

            case .titleChanged(let title):
                setText(.title, prov, t, title, into: \.title)

            case .meta, .ignored:
                break
            }
        }

        /// Clears the current tool unless a stronger, fresh source owns it.
        private mutating func clearTool(_ prov: Provenance, _ t: Date) {
            guard allowed(.tool, prov) else { return }
            s.currentTool = nil
            m.field[.tool] = nil
        }

        private func activity(_ info: ToolInfo, _ t: Date) -> ToolActivity {
            ToolActivity(name: info.name, summary: info.summary, startedAt: t, toolUseID: info.toolUseID)
        }

        private mutating func applyTaskMutation(_ mu: TaskMutation?, onStart: Bool, prov: Provenance, t: Date) {
            guard let mu = mu, allowed(.tasks, prov) else { return }
            // replaceAll carries the full final list in its input, so it is safe on tool start; incremental
            // mutations (TaskCreate needs the response for its id) are applied once, on completion.
            if case .replaceAll = mu {} else if onStart { return }
            var tasks = s.tasks
            SessionReducer.applyMutation(mu, to: &tasks)
            s.tasks = tasks; stamp(.tasks, prov, t)
        }

        // MARK: Subagents

        private mutating func upsertSubagent(id: String, type: String?, t: Date, status: SubagentStatus) {
            if let i = s.subagents.firstIndex(where: { $0.id == id }) {
                s.subagents[i].status = status
                if let ty = type { s.subagents[i].type = ty }
                return
            }
            if s.subagents.count >= ReducerLimits.maxSubagents {
                if let i = s.subagents.indices.filter({ s.subagents[$0].status != .running }).min(by: { s.subagents[$0].startedAt < s.subagents[$1].startedAt }) {
                    s.subagents.remove(at: i)
                } else { return }
            }
            s.subagents.append(Subagent(id: id, type: type, status: status, startedAt: t))
        }

        private mutating func updateSubagentTool(id: String, type: String?, tool: ToolActivity?, t: Date) {
            upsertSubagent(id: id, type: type, t: t, status: .running)
            if let i = s.subagents.firstIndex(where: { $0.id == id }), s.subagents[i].status == .running, let tool = tool {
                s.subagents[i].currentTool = tool
            }
        }

        private mutating func clearSubagentTool(id: String, toolUseID: String?) {
            guard let i = s.subagents.firstIndex(where: { $0.id == id }) else { return }
            if let cur = s.subagents[i].currentTool, toolUseID == nil || cur.toolUseID == nil || cur.toolUseID == toolUseID {
                s.subagents[i].currentTool = nil
            }
        }
    }

    // MARK: Discovery

    /// Merges passive-discovery results. `complete` = the scan finished normally; only then are vanished
    /// passive sessions marked done (a failed scan must not wipe the list).
    static func apply(discovered items: [DiscoveredSession], complete: Bool = true, policy: PassivePolicy = .default, to st: inout ReducerState, now: Date) {
        var seen = Set<SessionKey>()
        for item in items {
            var key = item.key
            if st.sessions[key] == nil, let pid = item.pid, pid > 1 {
                // Same process already known under another id (synthetic "pid:N" on one side)?
                if let existing = st.sessions.first(where: { $0.key.kind == item.key.kind && $0.value.pid == pid })?.key {
                    let existingSynthetic = existing.id.hasPrefix("pid:")
                    let itemSynthetic = item.key.id.hasPrefix("pid:")
                    if itemSynthetic { key = existing }
                    else if existingSynthetic { key = rekey(&st, from: existing, to: item.key) ?? item.key }
                }
            }
            if st.sessions[key] == nil {
                makeRoom(&st, protecting: key)
                var s = AgentSession(key: key, cwd: item.cwd, projectName: nil, status: item.status ?? .unknown, now: item.lastActivity ?? now)
                s.projectName = projectName(for: item.cwd)
                s.provenance = item.provenance
                st.sessions[key] = s
                st.meta[key] = SessionMeta()
            }
            seen.insert(key)
            var ed = Editor(s: st.sessions[key]!, m: st.meta[key] ?? SessionMeta(), now: now)
            ed.applyDiscovered(item)
            st.sessions[key] = ed.s
            st.meta[key] = ed.m
        }
        if complete {
            for (key, var s) in st.sessions where !seen.contains(key) {
                var m = st.meta[key] ?? SessionMeta()
                guard m.lastSeenByDiscovery != nil, !m.hookSeen, s.status != .done, s.status != .stopped else { continue }
                // One missed scan can be a transient hiccup: the session ends after `missesToEnd` consecutive misses.
                m.missCount += 1
                if m.missCount >= policy.missesToEnd { Editor.markEnded(&s, &m, now: now); st.sessions[key] = s }
                st.meta[key] = m
            }
        }
        mergeChildren(&st, now: now)
    }

    /// Mirrors child threads into their parent's `subagents` (the child itself is hidden by `sorted`).
    private static func mergeChildren(_ st: inout ReducerState, now: Date) {
        for (key, m) in st.meta.sorted(by: { $0.key.id < $1.key.id }) {
            guard let pk = m.parent, let child = st.sessions[key], var parent = st.sessions[pk] else { continue }
            let status: SubagentStatus
            switch child.status {
            case .failed: status = .failed
            case .needsPermission, .waitingInput: status = .waiting
            case .running, .starting: status = .running
            case .idle: status = .idle
            default: status = .done
            }
            if let i = parent.subagents.firstIndex(where: { $0.id == key.id }) {
                parent.subagents[i].status = status
                parent.subagents[i].lastText = child.lastAssistantText
            } else if parent.subagents.count < ReducerLimits.maxSubagents {
                parent.subagents.append(Subagent(id: key.id, type: child.title, status: status, startedAt: child.statusSince, currentTool: nil, lastText: child.lastAssistantText))
            }
            st.sessions[pk] = parent
        }
    }
}

extension SessionReducer.Editor {
    mutating func applyDiscovered(_ d: DiscoveredSession) {
        let t = d.lastActivity ?? now
        m.lastSeenByDiscovery = now
        m.missCount = 0
        if let pid = d.parentID, !pid.isEmpty { m.parent = SessionKey(kind: d.key.kind, id: pid) }
        if d.provenance > s.provenance { s.provenance = d.provenance }
        if !d.cwd.isEmpty, allowed(.cwd, d.provenance) {
            s.cwd = d.cwd; s.projectName = SessionReducer.projectName(for: d.cwd); stamp(.cwd, d.provenance, now)
        }
        if let pid = d.pid, allowed(.pid, d.provenance) {
            if s.pid != pid { s.processStart = nil }
            s.pid = pid; if let ps = d.processStart { s.processStart = ps }
            stamp(.pid, d.provenance, now)
        }
        if allowed(.host, d.provenance) {
            if let v = d.tty { s.tty = v }
            if let v = d.hostAppBundleID { s.hostAppBundleID = v }
            if let v = d.surface { s.surface = v }
            if let v = d.jump { s.jump = v }
            stamp(.host, d.provenance, now)
        }
        setText(.name, d.provenance, now, d.name, into: \.name)
        // The title is the user's latest prompt: weak on purpose so that an explicit title (hook, /rename) wins and a
        // newer prompt from either source replaces it.
        setText(.title, .processScan, now, d.title, into: \.title)
        setText(.prompt, d.textProvenance, now, d.lastPrompt, into: \.lastPrompt)
        setText(.assistant, d.textProvenance, now, d.lastAssistantText, into: \.lastAssistantText)
        setText(.model, d.textProvenance, now, d.model, into: \.model)
        setText(.transcript, d.textProvenance, now, d.transcriptPath, into: \.transcriptPath)
        if let tasks = d.tasks, allowed(.tasks, d.textProvenance) {
            s.tasks = Array(tasks.prefix(ReducerLimits.maxTasks)); stamp(.tasks, d.textProvenance, now)
        }
        if let subs = d.subagents, !m.hookSeen {
            for sub in subs {
                if let i = s.subagents.firstIndex(where: { $0.id == sub.id }) {
                    s.subagents[i].status = sub.status; if let l = sub.lastText { s.subagents[i].lastText = l }
                } else if s.subagents.count < ReducerLimits.maxSubagents { s.subagents.append(sub) }
            }
        }
        if let u = d.usage, allowed(.usage, d.textProvenance) { s.usage = u; stamp(.usage, d.textProvenance, now) }
        if let st = d.status, s.status != .done || d.provenance >= .registry {
            if setStatus(st, waitingFor: d.waitingFor, detail: d.statusDetail, prov: d.statusProvenance, t: d.statusSince ?? t), let since = d.statusSince {
                s.statusSince = since
            }
        }
        if let la = d.lastActivity { s.lastEventAt = max(s.lastEventAt, la) }
        else if s.status == .unknown { s.lastEventAt = max(s.lastEventAt, now) }
    }
}
