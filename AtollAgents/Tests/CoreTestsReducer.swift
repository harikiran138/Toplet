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

private let T0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { T0.addingTimeInterval(s) }
private let K = SessionKey(kind: .claudeCode, id: "s1")

private func tool(_ name: String = "Bash", _ summary: String = "npm test", id: String? = "t1", mutation: TaskMutation? = nil, subagent: Bool = false, spawned: String? = nil) -> ToolInfo {
    ToolInfo(name: name, summary: summary, toolUseID: id, taskMutation: mutation, spawnedAgentID: spawned, isSubagentTool: subagent)
}

@discardableResult
private func send(_ st: inout ReducerState, _ p: AgentEventPayload, _ t: TimeInterval, key: SessionKey = K, cwd: String? = "/work/proj",
                  prov: Provenance = .hook, agent: String? = nil, pid: Int32? = nil, model: String? = nil) -> AgentSession? {
    var e = AgentEvent(kind: key.kind, sessionID: key.id, payload: p, provenance: prov, cwd: cwd, model: model, agentID: agent, pid: pid)
    if prov != .hook { e.at = at(t) }
    SessionReducer.apply(e, to: &st, now: at(t))
    return st.sessions[key]
}

private func alive(_ pids: Set<Int32>) -> (Int32, Date?) -> Bool { { p, _ in pids.contains(p) } }

func runReducerTests() {
    section("Reducer: Claude event table (6.1)")
    var st = ReducerState()
    var s = send(&st, .sessionStart(source: "startup", title: nil), 0)!
    eq(s.status, .idle, "SessionStart(startup): idle")
    eq(s.cwd, "/work/proj", "cwd stored"); eq(s.projectName, "proj", "projectName is the last path component")
    check(s.isLive, "hook events mark the session live")
    s = send(&st, .promptSubmit(prompt: "fix the tests", title: nil), 1)!
    eq(s.status, .running, "UserPromptSubmit: running"); eq(s.lastPrompt ?? "", "fix the tests", "lastPrompt stored")
    eq(s.title ?? "", "fix the tests", "title is the user's prompt")
    s = send(&st, .promptSubmit(prompt: "second prompt", title: nil), 2)!
    eq(s.title ?? "", "second prompt", "title follows the user's LATEST prompt")
    eq(s.lastPrompt ?? "", "second prompt", "lastPrompt follows the latest prompt")
    s = send(&st, .toolStart(tool()), 3)!
    eq(s.currentTool?.summary ?? "", "npm test", "PreToolUse: currentTool"); eq(s.status, .running, "PreToolUse: running")
    s = send(&st, .permissionRequest(PermissionInfo(tool: tool(), mcpServer: nil, suggestions: [], suggestionEntries: [])), 4)!
    eq(s.status, .needsPermission, "PermissionRequest: needsPermission"); eq(s.waitingFor ?? "", "permission prompt", "PermissionRequest: waitingFor")
    s = send(&st, .toolStart(tool()), 4.1)!
    eq(s.status, .needsPermission, "PreToolUse for the same tool after PermissionRequest does not revert the status (hooks race)")
    s = send(&st, .approvalResolved(allowed: nil), 5)!
    eq(s.status, .needsPermission, "approval closed without a decision keeps needsPermission (terminal decides)")
    s = send(&st, .approvalResolved(allowed: true), 6)!
    eq(s.status, .running, "approval allowed in Toplet: running")
    send(&st, .permissionRequest(PermissionInfo(tool: tool("Edit", "/x"), mcpServer: nil, suggestions: [], suggestionEntries: [])), 7)
    s = send(&st, .approvalResolved(allowed: false), 8)!
    eq(s.status, .running, "approval denied in Toplet: running")
    send(&st, .permissionRequest(PermissionInfo(tool: tool("Edit", "/x"), mcpServer: nil, suggestions: [], suggestionEntries: [])), 9)
    s = send(&st, .toolEnd(tool("Edit", "/x", id: "t9"), failed: false), 10)!
    eq(s.status, .running, "PostToolUse while needsPermission: the tool ran, running")
    send(&st, .permissionRequest(PermissionInfo(tool: tool("Bash", "x"), mcpServer: nil, suggestions: [], suggestionEntries: [])), 11)
    s = send(&st, .permissionDenied(tool: "Bash", reason: nil), 12)!
    eq(s.status, .running, "PermissionDenied: running")
    s = send(&st, .toolEnd(tool(id: "other"), failed: false), 13)!
    check(s.currentTool != nil, "PostToolUse with a different tool_use_id keeps currentTool")
    s = send(&st, .toolEnd(tool(id: "t1"), failed: false), 14)!
    check(s.currentTool == nil, "PostToolUse with the matching id clears currentTool")
    send(&st, .toolStart(tool(id: nil)), 15)
    s = send(&st, .toolEnd(tool(id: nil), failed: true), 16)!
    check(s.currentTool == nil, "PostToolUseFailure without ids clears currentTool")
    s = send(&st, .notification(.idlePrompt, message: nil, title: nil), 17)!
    eq(s.status, .waitingInput, "Notification idle_prompt: waitingInput")
    s = send(&st, .promptSubmit(prompt: "go", title: nil), 18)!
    s = send(&st, .notification(.permissionPrompt, message: nil, title: nil), 19)!
    eq(s.status, .running, "Notification permission_prompt is ignored")
    s = send(&st, .notification(.agentNeedsInput, message: nil, title: nil), 20)!
    eq(s.status, .waitingInput, "Notification agent_needs_input: waitingInput")
    s = send(&st, .stop(lastMessage: "All done"), 21)!
    eq(s.status, .idle, "Stop: idle"); eq(s.lastAssistantText ?? "", "All done", "Stop: lastAssistantText"); check(s.currentTool == nil, "Stop clears the tool")
    s = send(&st, .notification(.authSuccess, message: nil, title: nil), 22)!
    eq(s.status, .idle, "other notifications do not change status")
    s = send(&st, .stopFailure(error: "rate_limit"), 23)!
    eq(s.status, .failed, "StopFailure: failed"); eq(s.waitingFor ?? "", "rate_limit", "StopFailure: error shown")
    s = send(&st, .toolStart(tool("Read", "/f", id: "z")), 24)!
    eq(s.status, .failed, "failed is sticky against later hook tool events")
    s = send(&st, .promptSubmit(prompt: "retry", title: nil), 25)!
    eq(s.status, .running, "next prompt clears failed"); check(s.waitingFor == nil, "next prompt clears the error text")
    s = send(&st, .sessionEnd(reason: "other"), 26)!
    eq(s.status, .done, "SessionEnd: done")
    s = send(&st, .stop(lastMessage: "late"), 27)!
    eq(s.status, .done, "a late Stop does not revive an ended session")
    s = send(&st, .toolStart(tool()), 28)!
    eq(s.status, .done, "a late tool event does not revive an ended session")
    s = send(&st, .sessionStart(source: "resume", title: nil), 29)!
    eq(s.status, .idle, "SessionStart(resume) revives an ended session")
    check(send(&st, .sessionEnd(reason: nil), 30, key: SessionKey(kind: .claudeCode, id: "never-seen")) == nil, "SessionEnd for an unknown session does not create one")

    section("Reducer: compaction, interrupt, resume, clear")
    var c = ReducerState()
    send(&c, .promptSubmit(prompt: "p", title: nil), 0)
    var cs = send(&c, .compact(isStart: true, trigger: "auto"), 1)!
    eq(cs.waitingFor ?? "", "compacting", "PreCompact: compacting badge"); eq(cs.status, .running, "PreCompact keeps running")
    cs = send(&c, .compact(isStart: false, trigger: "auto"), 2)!
    check(cs.waitingFor == nil, "PostCompact clears the badge")
    cs = send(&c, .interrupt, 3)!
    eq(cs.status, .idle, "Interrupt: idle"); eq(cs.waitingFor ?? "", "interrupted", "Interrupt: marked interrupted")
    var r = ReducerState()
    send(&r, .promptSubmit(prompt: "p", title: nil), 0)
    send(&r, .planUpdate([AgentTask(id: "1", title: "t", status: .pending)]), 1)
    var rs = send(&r, .sessionStart(source: "resume", title: nil), 2)!
    eq(rs.status, .running, "SessionStart(resume) keeps the current status"); eq(rs.tasks.count, 1, "resume keeps tasks")
    rs = send(&r, .sessionStart(source: "clear", title: nil), 3)!
    eq(rs.status, .idle, "SessionStart(clear): idle"); eq(rs.tasks.count, 0, "clear drops tasks")
    rs = send(&r, .sessionStart(source: "startup", title: "Named"), 4)!
    eq(rs.title ?? "", "Named", "SessionStart session_title becomes the title")

    section("Reducer: subagents")
    var sa = ReducerState()
    send(&sa, .promptSubmit(prompt: "p", title: nil), 0)
    var ss = send(&sa, .subagentStart(id: "a1", type: "Explore"), 1)!
    eq(ss.subagents.count, 1, "SubagentStart adds a subagent"); eq(ss.subagents[0].status, .running, "subagent is running"); eq(ss.subagents[0].type ?? "", "Explore", "subagent type")
    ss = send(&sa, .toolStart(tool("Grep", "TODO", id: "g1")), 2, agent: "a1")!
    eq(ss.subagents[0].currentTool?.summary ?? "", "TODO", "tool events with agent_id go to the subagent"); check(ss.currentTool == nil, "...and not to the parent session")
    ss = send(&sa, .toolEnd(tool("Grep", "TODO", id: "g1"), failed: false), 3, agent: "a1")!
    check(ss.subagents[0].currentTool == nil, "PostToolUse inside the subagent clears its tool")
    ss = send(&sa, .toolStart(tool("Bash", "ls", id: "p1")), 3.5, agent: "unseen")!
    eq(ss.subagents.count, 2, "an event from an unseen subagent registers it")
    ss = send(&sa, .subagentStop(id: "a1", type: nil, lastMessage: "found it", failed: false), 4)!
    eq(ss.subagents.first(where: { $0.id == "a1" })?.status ?? .running, .done, "SubagentStop: done"); eq(ss.subagents.first(where: { $0.id == "a1" })?.lastText ?? "", "found it", "SubagentStop: lastText")
    ss = send(&sa, .toolEnd(tool("Agent", "x", id: "ag", subagent: true, spawned: "unseen"), failed: false), 5)!
    eq(ss.subagents.first(where: { $0.id == "unseen" })?.status ?? .running, .done, "Agent tool completion finishes the subagent it names")
    var many = ReducerState()
    for i in 0..<40 { send(&many, .subagentStart(id: "a\(i)", type: nil), Double(i)) }
    eq(many.sessions[K]!.subagents.count, 32, "subagents are bounded to 32 (all running: extras dropped)")
    var many2 = ReducerState()
    for i in 0..<32 { send(&many2, .subagentStart(id: "a\(i)", type: nil), Double(i)) }
    send(&many2, .subagentStop(id: "a3", type: nil, lastMessage: nil, failed: false), 40)
    send(&many2, .subagentStart(id: "new", type: nil), 41)
    check(many2.sessions[K]!.subagents.contains(where: { $0.id == "new" }) && !many2.sessions[K]!.subagents.contains(where: { $0.id == "a3" }), "a finished subagent is evicted to make room")

    section("Reducer: tasks")
    var tk = ReducerState()
    send(&tk, .promptSubmit(prompt: "p", title: nil), 0)
    var t1 = send(&tk, .toolStart(tool("TodoWrite", "2 todos", id: "w", mutation: .replaceAll([AgentTask(id: "a", title: "A", status: .inProgress), AgentTask(id: "b", title: "B", status: .pending)]))), 1)!
    eq(t1.tasks.map { $0.title }, ["A", "B"], "TodoWrite replaces the list (applied on tool start)")
    t1 = send(&tk, .toolEnd(tool("TaskCreate", "C", id: "c", mutation: .create(AgentTask(id: "", title: "C", status: .pending))), failed: false), 2)!
    eq(t1.tasks.count, 3, "TaskCreate appends on completion"); check(Int(t1.tasks[2].id) != nil, "TaskCreate without an id gets a numeric id")
    let cid = t1.tasks[2].id
    t1 = send(&tk, .toolEnd(tool("TaskUpdate", "x", id: "u", mutation: .update(id: cid, status: .completed, title: nil, activeForm: nil)), failed: false), 3)!
    eq(t1.tasks[2].status, .completed, "TaskUpdate changes status")
    t1 = send(&tk, .toolEnd(tool("TaskUpdate", "x", id: "u2", mutation: .update(id: "a", status: nil, title: "A2", activeForm: "Doing A2")), failed: false), 4)!
    eq(t1.tasks[0].title, "A2", "TaskUpdate changes title"); eq(t1.tasks[0].activeForm ?? "", "Doing A2", "TaskUpdate changes activeForm")
    t1 = send(&tk, .toolEnd(tool("TaskUpdate", "x", id: "u3", mutation: .delete(id: "b")), failed: false), 5)!
    eq(t1.tasks.map { $0.id }.contains("b"), false, "TaskUpdate(deleted) removes the task"); eq(t1.tasks.map { $0.order }, [0, 1], "orders are reindexed")
    t1 = send(&tk, .toolEnd(tool("TaskCreate", "boom", id: "f", mutation: .create(AgentTask(id: "", title: "never", status: .pending))), failed: true), 6)!
    check(!t1.tasks.contains(where: { $0.title == "never" }), "a failed TaskCreate changes nothing")
    t1 = send(&tk, .toolStart(tool("TaskCreate", "early", id: "e", mutation: .create(AgentTask(id: "", title: "early", status: .pending)))), 7)!
    check(!t1.tasks.contains(where: { $0.title == "early" }), "incremental mutations wait for completion")
    t1 = send(&tk, .taskCreated(id: "77", subject: "From hook", description: nil), 8)!
    check(t1.tasks.contains(where: { $0.id == "77" }), "TaskCreated hook adds a task")
    t1 = send(&tk, .taskCompleted(id: "77", subject: nil), 9)!
    eq(t1.tasks.first(where: { $0.id == "77" })?.status ?? .pending, .completed, "TaskCompleted hook completes it")
    t1 = send(&tk, .taskCompleted(id: "88", subject: "Unseen task"), 10)!
    eq(t1.tasks.first(where: { $0.id == "88" })?.title ?? "", "Unseen task", "TaskCompleted for an unseen task creates it")
    t1 = send(&tk, .toolEnd(tool("TaskCreate", "Dup me", id: "d1", mutation: .create(AgentTask(id: "", title: "Dup me", status: .pending))), failed: false), 11)!
    let before = t1.tasks.count
    t1 = send(&tk, .taskCreated(id: "501", subject: "dup ME", description: nil), 11.5)!
    eq(t1.tasks.count, before, "a TaskCreated hook duplicating a pending task title is merged (hook + tool both fire)")
    check(t1.tasks.contains(where: { $0.id == "501" }), "...and adopts the hook's id")
    var big = ReducerState()
    let many300 = (0..<300).map { AgentTask(id: "t\($0)", title: "T\($0)", status: .pending, order: $0) }
    let bs = send(&big, .planUpdate(many300), 0)!
    eq(bs.tasks.count, 200, "tasks are bounded to 200")
    var tasks = bs.tasks
    SessionReducer.applyMutation(.create(AgentTask(id: "", title: "overflow", status: .pending)), to: &tasks)
    eq(tasks.count, 200, "creating beyond the bound is ignored")
    let ps = send(&tk, .planUpdate([AgentTask(id: "p1", title: "Plan", status: .inProgress)]), 12)!
    eq(ps.tasks.map { $0.title }, ["Plan"], "plan_update replaces the checklist (Codex)")

    section("Reducer: Codex rollout table (6.2)")
    let CK = SessionKey(kind: .codex, id: "cx1")
    var cx = ReducerState()
    var x = send(&cx, .meta, 0, key: CK, prov: .rollout)!
    x = send(&cx, .turnStarted, 1, key: CK, prov: .rollout)!
    eq(x.status, .running, "rollout task_started: running"); check(!x.isLive, "rollout events never mark a session live")
    x = send(&cx, .approvalNeeded(waitingFor: "permission prompt"), 2, key: CK, prov: .rollout)!
    eq(x.status, .needsPermission, "rollout approval request: needsPermission (read-only)")
    x = send(&cx, .toolStart(tool("exec_command", "make", id: "c1")), 3, key: CK, prov: .rollout)!
    eq(x.status, .running, "rollout exec_command_begin after the request: running again")
    x = send(&cx, .approvalNeeded(waitingFor: "input needed"), 4, key: CK, prov: .rollout)!
    eq(x.status, .waitingInput, "rollout request_user_input: waitingInput")
    x = send(&cx, .turnCompleted(lastMessage: "Finished"), 5, key: CK, prov: .rollout)!
    eq(x.status, .idle, "rollout task_complete: idle"); eq(x.lastAssistantText ?? "", "Finished", "rollout task_complete: last message")
    x = send(&cx, .turnStarted, 6, key: CK, prov: .rollout)!
    x = send(&cx, .turnAborted, 7, key: CK, prov: .rollout)!
    eq(x.status, .idle, "rollout turn_aborted: idle"); eq(x.waitingFor ?? "", "interrupted", "rollout turn_aborted: interrupted")
    x = send(&cx, .shutdown, 8, key: CK, prov: .rollout)!
    eq(x.status, .done, "rollout shutdown_complete: done")
    x = send(&cx, .usage(UsageSnapshot(fiveHourPercent: 10, source: "codex rollout")), 9, key: CK, prov: .rollout)!
    eq(x.usage?.fiveHourPercent ?? -1, 10, "usage stored")
    x = send(&cx, .usage(UsageSnapshot(sevenDayPercent: 33, source: "codex rollout")), 10, key: CK, prov: .rollout)!
    check(x.usage?.fiveHourPercent == 10 && x.usage?.sevenDayPercent == 33, "usage snapshots merge field by field")
    var cxh = ReducerState()
    send(&cxh, .promptSubmit(prompt: "p", title: nil), 0, key: CK)
    var xh = send(&cxh, .interrupt, 1, key: CK)!
    eq(xh.status, .idle, "codex hook Interrupt: idle"); eq(xh.waitingFor ?? "", "interrupted", "codex hook Interrupt: interrupted")
    xh = send(&cxh, .permissionRequest(PermissionInfo(tool: tool("Bash", "rm -rf build"), mcpServer: nil, suggestions: [], suggestionEntries: [])), 2, key: CK)!
    eq(xh.status, .needsPermission, "codex hook PermissionRequest: needsPermission")

    section("Reducer: provenance (strongest wins per field)")
    var pv = ReducerState()
    send(&pv, .promptSubmit(prompt: "p", title: nil), 0)                    // hook: running at t=0
    var item = DiscoveredSession(key: K, provenance: .registry, cwd: "/work/proj")
    item.status = .idle; item.statusProvenance = .registry; item.title = "Registry title"; item.textProvenance = .transcript
    SessionReducer.apply(discovered: [item], to: &pv, now: at(10))
    var p1 = pv.sessions[K]!
    eq(p1.status, .running, "a registry status does not override a fresh hook status")
    eq(p1.title ?? "", "Registry title", "...but a stronger-than-first-prompt title is accepted")
    var pv2 = pv
    SessionReducer.apply(discovered: [item], to: &pv2, now: at(200))
    p1 = pv2.sessions[K]!
    eq(p1.status, .idle, "a weaker source overrides a hook status that went stale (> 90 s)")
    var pv3 = ReducerState()
    send(&pv3, .sessionStart(source: "startup", title: "Hook title"), 0)
    var weak = DiscoveredSession(key: K, provenance: .transcript, cwd: "/w")
    weak.title = "Transcript title"; weak.textProvenance = .transcript
    SessionReducer.apply(discovered: [weak], to: &pv3, now: at(5))
    eq(pv3.sessions[K]!.title ?? "", "Hook title", "hook title beats transcript title")
    var pv4 = ReducerState()
    send(&pv4, .promptSubmit(prompt: "prompt title", title: nil), 0, prov: .transcript)
    send(&pv4, .titleChanged("ai title"), 1, prov: .transcript)
    eq(pv4.sessions[K]!.title ?? "", "ai title", "an explicit title beats the first-prompt fallback")
    var pv5 = ReducerState()
    send(&pv5, .toolStart(tool()), 0, prov: .hook)
    send(&pv5, .toolEnd(tool(), failed: false), 1, prov: .transcript)
    check(pv5.sessions[K]!.currentTool != nil, "a transcript event cannot clear a hook-owned tool")

    section("Reducer: rekey of synthetic pid sessions")
    var rk = ReducerState()
    var d1 = DiscoveredSession(key: SessionKey(kind: .claudeCode, id: "pid:4242"), provenance: .processScan, cwd: "/w")
    d1.pid = 4242
    SessionReducer.apply(discovered: [d1], to: &rk, now: at(0))
    check(rk.sessions[SessionKey(kind: .claudeCode, id: "pid:4242")] != nil, "process-only session is keyed pid:N")
    send(&rk, .stop(lastMessage: nil), 1, key: SessionKey(kind: .claudeCode, id: "real-id"), pid: 4242)
    check(rk.sessions[SessionKey(kind: .claudeCode, id: "pid:4242")] == nil && rk.sessions[SessionKey(kind: .claudeCode, id: "real-id")] != nil, "a hook event with the same ppid takes over the synthetic session")
    eq(rk.sessions.count, 1, "no duplicate left behind")
    var rk2 = ReducerState()
    var dReal = DiscoveredSession(key: SessionKey(kind: .claudeCode, id: "real-2"), provenance: .registry, cwd: "/w"); dReal.pid = 99
    SessionReducer.apply(discovered: [dReal], to: &rk2, now: at(0))
    var dSyn = DiscoveredSession(key: SessionKey(kind: .claudeCode, id: "pid:99"), provenance: .processScan, cwd: "/w"); dSyn.pid = 99
    SessionReducer.apply(discovered: [dSyn], to: &rk2, now: at(1))
    eq(rk2.sessions.count, 1, "a pid-only discovery of an already known process does not duplicate it")

    section("Reducer: bounds")
    var bd = ReducerState()
    for i in 0..<100 { send(&bd, .promptSubmit(prompt: "p", title: nil), Double(i), key: SessionKey(kind: .claudeCode, id: "n\(i)")) }
    eq(bd.sessions.count, 64, "max 64 sessions")
    check(bd.sessions[SessionKey(kind: .claudeCode, id: "n99")] != nil, "the newest session survives")
    check(bd.sessions[SessionKey(kind: .claudeCode, id: "n0")] == nil, "the oldest idle-ish session is evicted")
    var bd2 = ReducerState()
    for i in 0..<64 { send(&bd2, .promptSubmit(prompt: "p", title: nil), Double(i), key: SessionKey(kind: .claudeCode, id: "n\(i)")) }
    send(&bd2, .sessionEnd(reason: nil), 100, key: SessionKey(kind: .claudeCode, id: "n30"))
    send(&bd2, .promptSubmit(prompt: "p", title: nil), 101, key: SessionKey(kind: .claudeCode, id: "fresh"))
    check(bd2.sessions[SessionKey(kind: .claudeCode, id: "n30")] == nil && bd2.sessions[SessionKey(kind: .claudeCode, id: "n0")] != nil, "ended sessions are evicted before running ones")
    var bd3 = ReducerState()
    for i in 0..<64 { send(&bd3, .permissionRequest(PermissionInfo(tool: tool(), mcpServer: nil, suggestions: [], suggestionEntries: [])), Double(i), key: SessionKey(kind: .claudeCode, id: "n\(i)")) }
    send(&bd3, .promptSubmit(prompt: "p", title: nil), 200, key: SessionKey(kind: .claudeCode, id: "extra"))
    eq(bd3.sessions.count, 64, "still 64 when every session needs attention")
    let longStr = String(repeating: "x", count: 5000)
    send(&bd3, .toolStart(ToolInfo(name: "t", summary: longStr)), 201, key: SessionKey(kind: .claudeCode, id: "extra"), cwd: String(repeating: "/a", count: 3000))
    check(bd3.sessions[SessionKey(kind: .claudeCode, id: "extra")] != nil, "oversized fields do not break the reducer")

    section("Reducer: expiry")
    var ex = ReducerState()
    send(&ex, .promptSubmit(prompt: "p", title: nil), 0)
    SessionReducer.expire(&ex, now: at(300), isPidAlive: alive([]))
    eq(ex.sessions[K]!.status, .running, "running within 10 minutes stays running")
    SessionReducer.expire(&ex, now: at(601), isPidAlive: alive([]))
    eq(ex.sessions[K]!.status, .unknown, "running without events for 10 min and no pid -> unknown")
    SessionReducer.expire(&ex, now: at(601 + 3601), isPidAlive: alive([]))
    check(ex.sessions[K] == nil, "unknown sessions are dropped after an hour")
    var ex2 = ReducerState()
    send(&ex2, .promptSubmit(prompt: "p", title: nil), 0, pid: 500)
    SessionReducer.expire(&ex2, now: at(700), isPidAlive: alive([500]))
    eq(ex2.sessions[K]!.status, .running, "running with a live pid is not expired")
    SessionReducer.expire(&ex2, now: at(700), isPidAlive: alive([]))
    eq(ex2.sessions[K]!.status, .done, "a dead pid marks the session done")
    SessionReducer.expire(&ex2, now: at(700 + 299), isPidAlive: alive([]))
    check(ex2.sessions[K] != nil, "ended sessions are kept for 5 minutes")
    SessionReducer.expire(&ex2, now: at(700 + 301), isPidAlive: alive([]))
    check(ex2.sessions[K] == nil, "ended sessions drop after 5 minutes")
    var ex3 = ReducerState()
    send(&ex3, .promptSubmit(prompt: "p", title: nil), 0, pid: 600)
    SessionReducer.expire(&ex3, now: at(5), isPidAlive: alive([]))
    eq(ex3.sessions[K]!.status, .running, "a freshly dead pid gets a short grace period")
    var ex4 = ReducerState()
    send(&ex4, .sessionEnd(reason: nil), 0, key: K)
    send(&ex4, .sessionStart(source: "startup", title: nil), 0)
    send(&ex4, .sessionEnd(reason: nil), 1)
    SessionReducer.expire(&ex4, now: at(1 + 301), isPidAlive: alive([]))
    check(ex4.sessions[K] == nil, "SessionEnd then expiry drops the session")

    section("Reducer: ordering and determinism")
    var so = ReducerState()
    send(&so, .promptSubmit(prompt: "p", title: nil), 10, key: SessionKey(kind: .claudeCode, id: "old"))
    send(&so, .promptSubmit(prompt: "p", title: nil), 50, key: SessionKey(kind: .claudeCode, id: "new"))
    send(&so, .permissionRequest(PermissionInfo(tool: tool(), mcpServer: nil, suggestions: [], suggestionEntries: [])), 20, key: SessionKey(kind: .claudeCode, id: "perm"))
    send(&so, .notification(.idlePrompt, message: nil, title: nil), 15, key: SessionKey(kind: .claudeCode, id: "wait"))
    send(&so, .stopFailure(error: "x"), 5, key: SessionKey(kind: .claudeCode, id: "fail"))
    eq(SessionReducer.sorted(so).map { $0.key.id }, ["perm", "wait", "fail", "new", "old"], "attention first (by recency), then the rest by recency")
    var tie = ReducerState()
    for id in ["b", "a", "c"] { send(&tie, .promptSubmit(prompt: "p", title: nil), 1, key: SessionKey(kind: .claudeCode, id: id)) }
    eq(SessionReducer.sorted(tie).map { $0.key.id }, ["claude:a", "claude:b", "claude:c"].map { String($0.dropFirst(7)) }, "ties break by id: the order is stable")
    func run() -> ReducerState {
        var s = ReducerState()
        send(&s, .sessionStart(source: "startup", title: nil), 0)
        send(&s, .promptSubmit(prompt: "x", title: nil), 1)
        send(&s, .toolStart(tool()), 2)
        send(&s, .permissionRequest(PermissionInfo(tool: tool(), mcpServer: nil, suggestions: [], suggestionEntries: [])), 3)
        send(&s, .subagentStart(id: "a", type: nil), 4)
        send(&s, .stop(lastMessage: "ok"), 5)
        return s
    }
    check(run() == run(), "the same event sequence always produces the same state (deterministic)")
    var fu = ReducerState()
    var e = AgentEvent(kind: .claudeCode, sessionID: "f", payload: .stop(lastMessage: nil), provenance: .rollout, at: at(10_000))
    SessionReducer.apply(e, to: &fu, now: at(0))
    check(fu.sessions[SessionKey(kind: .claudeCode, id: "f")]!.lastEventAt <= at(5), "event timestamps from the future are clamped to now")
    e = AgentEvent(kind: .claudeCode, sessionID: "f", payload: .meta, provenance: .hook)
    SessionReducer.apply(e, to: &fu, now: at(1))
    eq(fu.sessions[SessionKey(kind: .claudeCode, id: "f")]!.cwd, "", "no cwd stays empty")
    var cw = ReducerState()
    send(&cw, .meta, 0, cwd: nil)
    let cwd1 = send(&cw, .meta, 1, cwd: "/a/b/")!
    eq(cwd1.projectName, "b", "a trailing slash does not break projectName")

    section("Reducer: discovery merge")
    var dm = ReducerState()
    var di = DiscoveredSession(key: SessionKey(kind: .claudeCode, id: "reg-1"), provenance: .registry, cwd: "/Users/x/app")
    di.pid = 321; di.processStart = at(-100); di.tty = "/dev/ttys004"; di.hostAppBundleID = "com.apple.Terminal"; di.surface = .terminal
    di.jump = .terminal(bundleID: "com.apple.Terminal", tty: "/dev/ttys004"); di.status = .running; di.name = "My session"; di.lastActivity = at(-5)
    di.title = "A title"; di.lastPrompt = "do it"; di.tasks = [AgentTask(id: "1", title: "t", status: .pending)]
    SessionReducer.apply(discovered: [di], to: &dm, now: at(0))
    let dsess = dm.sessions[di.key]!
    eq(dsess.pid ?? 0, 321, "discovered pid"); eq(dsess.tty ?? "", "/dev/ttys004", "discovered tty"); eq(dsess.status, .running, "discovered status")
    eq(dsess.name ?? "", "My session", "discovered name"); eq(dsess.projectName, "app", "discovered projectName"); check(!dsess.isLive, "discovered sessions are not live")
    eq(dsess.surface, .terminal, "discovered surface"); eq(dsess.tasks.count, 1, "discovered tasks"); eq(dsess.lastEventAt, at(-5), "lastEventAt follows lastActivity")
    SessionReducer.apply(discovered: [], complete: false, to: &dm, now: at(30))
    check(dm.sessions[di.key]!.status == .running, "an incomplete scan does not end sessions")
    SessionReducer.apply(discovered: [], complete: true, to: &dm, now: at(60))
    eq(dm.sessions[di.key]!.status, .running, "one missed scan does not end a passive session")
    SessionReducer.apply(discovered: [], complete: true, to: &dm, now: at(75))
    eq(dm.sessions[di.key]!.status, .done, "a passive session missing from 2 consecutive complete scans is done")
    var dm2 = ReducerState()
    send(&dm2, .promptSubmit(prompt: "p", title: nil), 0)
    SessionReducer.apply(discovered: [], complete: true, to: &dm2, now: at(60))
    eq(dm2.sessions[K]!.status, .running, "hook sessions are not ended by discovery")
    var dm3 = ReducerState()
    di.status = .needsPermission; di.waitingFor = "permission prompt"; di.statusProvenance = .registry
    SessionReducer.apply(discovered: [di], to: &dm3, now: at(0))
    eq(dm3.sessions[di.key]!.status, .needsPermission, "registry waiting + permission prompt: needsPermission")
    eq(dm3.sessions[di.key]!.waitingFor ?? "", "permission prompt", "waitingFor carried")
}
