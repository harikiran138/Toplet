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

private func dec(_ o: [String: Any], ppid: Int32? = nil) -> AgentEvent? { ClaudeEvents.decode(o, ppid: ppid) }
private func decx(_ o: [String: Any], ppid: Int32? = nil) -> AgentEvent? { CodexEvents.decodeHook(o, ppid: ppid) }

func runEventTests() {
    section("Claude hook events")
    // One check per fixture: decodes to the right payload kind.
    for (name, json) in Fx.claudeEvents {
        let e = dec(json)
        check(e != nil && e!.kind == .claudeCode && e!.sessionID == Fx.sid, "claude \(name): decodes and keeps the session id")
    }
    if case .sessionStart(let src, _)? = dec(Fx.claude("SessionStart", ["source": "resume", "session_title": "My title"]))?.payload {
        eq(src ?? "", "resume", "SessionStart: source")
    } else { check(false, "SessionStart payload") }
    if case .sessionStart(_, let t)? = dec(Fx.claude("SessionStart", ["session_title": "My title"]))?.payload { eq(t ?? "", "My title", "SessionStart: session_title") } else { check(false, "SessionStart title") }
    let start = dec(Fx.claude("SessionStart", ["model": "claude-opus-4-7"]))!
    eq(start.cwd ?? "", Fx.cwd, "common: cwd")
    eq(start.model ?? "", "claude-opus-4-7", "common: model")
    eq(start.permissionMode ?? "", "default", "common: permission_mode")
    check((start.transcriptPath ?? "").hasSuffix("\(Fx.sid).jsonl"), "common: transcript_path")
    eq(start.promptID ?? "", "9d6f0c0e-0000-4000-8000-000000000001", "common: prompt_id")
    eq(dec(Fx.claude("SessionStart"), ppid: 4242)!.pid ?? 0, 4242, "envelope ppid is carried on the event")
    if case .sessionEnd(let r)? = dec(Fx.claude("SessionEnd", ["reason": "clear"]))?.payload { eq(r ?? "", "clear", "SessionEnd: reason") } else { check(false, "SessionEnd") }
    if case .promptSubmit(let p, _)? = dec(Fx.claude("UserPromptSubmit", ["prompt": "do\u{202E} it\nnow"]))?.payload { eq(p ?? "", "do it now", "UserPromptSubmit: prompt is sanitised") } else { check(false, "UserPromptSubmit") }
    if case .toolStart(let t)? = dec(Fx.claudeEvents[3].json)?.payload {
        eq(t.name, "Bash", "PreToolUse: tool name"); eq(t.summary, "npm test", "PreToolUse: summary"); eq(t.toolUseID ?? "", "toolu_01", "PreToolUse: tool_use_id")
    } else { check(false, "PreToolUse") }
    eq(dec(Fx.claude("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "x"], "agent_id": "a9", "agent_type": "Explore"]))!.agentID ?? "", "a9", "events from inside a subagent carry agent_id")
    // PermissionRequest
    if case .permissionRequest(let info)? = dec(Fx.claudeEvents[4].json)?.payload {
        eq(info.tool.name, "Bash", "PermissionRequest: tool")
        eq(info.suggestions.count, 1, "PermissionRequest: one suggestion offered")
        eq(info.suggestions.first?.label ?? "", "Always allow Bash(npm test:*)", "PermissionRequest: suggestion label")
        eq(info.suggestions.first?.id ?? -1, 0, "PermissionRequest: suggestion id is the agent's list index")
        check(info.tool.detail != nil, "PermissionRequest: has a detail preview")
        check((try? JSONSerialization.jsonObject(with: info.suggestionEntries[0])) is [String: Any], "PermissionRequest: sanitised entry kept as JSON")
    } else { check(false, "PermissionRequest") }
    let sugg: [[String: Any]] = [
        ["type": "setMode", "mode": "bypassPermissions"],
        ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "ls"]], "behavior": "deny", "destination": "session"],
        ["type": "somethingNew", "x": 1],
        ["type": "addRules", "rules": [["toolName": "Edit"]], "behavior": "allow", "destination": "session", "evil": "ignored"],
        ["type": "setMode", "mode": "acceptEdits"],
        ["type": "addDirectories", "directories": ["/tmp/work"]],
        ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "a\u{202E}b"]], "behavior": "allow", "destination": "hacker"],
    ]
    if case .permissionRequest(let info)? = dec(Fx.claude("PermissionRequest", ["tool_name": "Edit", "tool_input": ["file_path": "/x"], "permission_suggestions": sugg]))?.payload {
        eq(info.suggestions.map { $0.id }, [3, 4, 5, 6], "suggestions: unsafe/unknown kinds are not offered, indices preserved")
        eq(info.suggestions[0].label, "Allow Edit for this session", "suggestion: session-scoped label")
        eq(info.suggestions[1].label, "Switch to acceptEdits mode", "suggestion: safe setMode")
        check(info.suggestions[2].label.hasPrefix("Allow access to /tmp/work"), "suggestion: addDirectories")
        eq(info.suggestionEntries.count, 7, "suggestion entries indexed like the agent's list")
        let e3 = (try? JSONSerialization.jsonObject(with: info.suggestionEntries[3])) as? [String: Any]
        check(e3?["evil"] == nil, "suggestion entry drops unknown keys")
        let e6 = (try? JSONSerialization.jsonObject(with: info.suggestionEntries[6])) as? [String: Any]
        check(e6?["destination"] == nil, "suggestion entry drops an unknown destination")
        check(info.suggestionEntries[0].isEmpty, "suggestion not offered has an empty entry")
    } else { check(false, "PermissionRequest suggestions") }
    if case .permissionRequest(let info)? = dec(Fx.claude("PermissionRequest", ["tool_name": "mcp__gh__pr", "tool_input": [:], "mcp_server": "gh"]))?.payload {
        eq(info.mcpServer ?? "", "gh", "PermissionRequest: mcp_server"); eq(info.suggestions.count, 0, "PermissionRequest: no suggestions is fine")
    } else { check(false, "PermissionRequest mcp") }
    if case .toolEnd(let t, let failed)? = dec(Fx.claudeEvents[5].json)?.payload { check(!failed, "PostToolUse: not failed"); eq(t.durationMS ?? 0, 1234, "PostToolUse: duration_ms") } else { check(false, "PostToolUse") }
    if case .toolEnd(let t, let failed)? = dec(Fx.claudeEvents[6].json)?.payload { check(failed, "PostToolUseFailure: failed"); eq(t.errorText ?? "", "exit 1", "PostToolUseFailure: error text") } else { check(false, "PostToolUseFailure") }
    if case .permissionDenied(let tool, _)? = dec(Fx.claudeEvents[7].json)?.payload { eq(tool ?? "", "Bash", "PermissionDenied: tool") } else { check(false, "PermissionDenied") }
    func notif(_ type: String?, msg: String = "m") -> NotificationKind? {
        var x: [String: Any] = ["message": msg]; if let t = type { x["notification_type"] = t }
        if case .notification(let k, _, _)? = dec(Fx.claude("Notification", x))?.payload { return k }; return nil
    }
    check(notif("permission_prompt") == .permissionPrompt, "Notification: permission_prompt")
    check(notif("idle_prompt") == .idlePrompt, "Notification: idle_prompt")
    check(notif("agent_needs_input") == .agentNeedsInput, "Notification: agent_needs_input")
    check(notif("agent_completed") == .agentCompleted, "Notification: agent_completed")
    check(notif("auth_success") == .authSuccess, "Notification: auth_success")
    check(notif("elicitation_dialog") == .elicitation, "Notification: elicitation_dialog")
    check(notif("quota_auto_resume_x") == .other("quota_auto_resume_x"), "Notification: unknown type is kept as other")
    check(notif(nil, msg: "Claude needs your permission to use Bash") == .permissionPrompt, "Notification: no type, permission wording")
    check(notif(nil, msg: "Claude is waiting for your input") == .idlePrompt, "Notification: no type, idle wording")
    if case .stop(let m)? = dec(Fx.claudeEvents[9].json)?.payload { eq(m ?? "", "Done. All tests pass.", "Stop: last_assistant_message") } else { check(false, "Stop") }
    if case .stopFailure(let e)? = dec(Fx.claudeEvents[10].json)?.payload { eq(e ?? "", "rate_limit", "StopFailure: error") } else { check(false, "StopFailure") }
    let ss = dec(Fx.claudeEvents[11].json)!
    if case .subagentStart(let id, let type) = ss.payload { eq(id, "agent-1", "SubagentStart: id"); eq(type ?? "", "Explore", "SubagentStart: type") } else { check(false, "SubagentStart") }
    check(ss.agentID == nil, "SubagentStart: event is not attributed to the subagent itself")
    if case .subagentStop(let id, _, let last, _)? = dec(Fx.claudeEvents[12].json)?.payload { eq(id, "agent-1", "SubagentStop: id"); eq(last ?? "", "found it", "SubagentStop: last message") } else { check(false, "SubagentStop") }
    if case .taskCreated(let id, let subj, _)? = dec(Fx.claudeEvents[13].json)?.payload { eq(id, "1", "TaskCreated: id"); eq(subj, "Write tests", "TaskCreated: subject") } else { check(false, "TaskCreated") }
    if case .taskCompleted(let id, _)? = dec(Fx.claudeEvents[14].json)?.payload { eq(id, "1", "TaskCompleted: id") } else { check(false, "TaskCompleted") }
    if case .taskCreated(let id, _, _)? = dec(Fx.claude("TaskCreated", ["task_id": 12, "task_subject": "n"]))?.payload { eq(id, "12", "TaskCreated: numeric task_id") } else { check(false, "TaskCreated numeric") }
    if case .compact(let isStart, let trig)? = dec(Fx.claudeEvents[15].json)?.payload { check(isStart, "PreCompact: start"); eq(trig ?? "", "auto", "PreCompact: trigger") } else { check(false, "PreCompact") }
    if case .compact(let isStart, _)? = dec(Fx.claudeEvents[16].json)?.payload { check(!isStart, "PostCompact: end") } else { check(false, "PostCompact") }

    section("Claude tool inputs -> tasks")
    if case .toolStart(let t)? = dec(Fx.claude("PreToolUse", ["tool_name": "TodoWrite", "tool_input": ["todos": [
        ["content": "Read", "status": "completed", "activeForm": "Reading"], ["content": "Edit", "status": "in_progress", "activeForm": "Editing"], ["content": "Test", "status": "pending"], ["content": "", "status": "pending"]]]]))?.payload,
       case .replaceAll(let tasks)? = t.taskMutation {
        eq(tasks.map { $0.title }, ["Read", "Edit", "Test"], "TodoWrite: titles (empty ones skipped)")
        eq(tasks.map { $0.status }, [.completed, .inProgress, .pending], "TodoWrite: statuses")
        eq(tasks[1].activeForm ?? "", "Editing", "TodoWrite: activeForm")
    } else { check(false, "TodoWrite mutation") }
    func createID(_ response: Any?) -> String? {
        var x = Fx.claude("PostToolUse", ["tool_name": "TaskCreate", "tool_input": ["subject": "Do X", "description": "d"]])
        if let r = response { x["tool_response"] = r }
        if case .toolEnd(let t, _)? = dec(x)?.payload, case .create(let task)? = t.taskMutation { return task.id }
        return nil
    }
    eq(createID("Task #7 created successfully: Do X") ?? "nil", "7", "TaskCreate: id from response text")
    eq(createID(["taskId": "9"]) ?? "nil", "9", "TaskCreate: id from response dict")
    eq(createID(["task": ["id": 3]]) ?? "nil", "3", "TaskCreate: id from nested response")
    eq(createID(nil) ?? "nil", "", "TaskCreate: no response leaves the id for the reducer")
    if case .toolEnd(let t, _)? = dec(Fx.claude("PostToolUse", ["tool_name": "TaskUpdate", "tool_input": ["taskId": "2", "status": "completed"]]))?.payload,
       case .update(let id, let st, _, _)? = t.taskMutation { eq(id, "2", "TaskUpdate: id"); check(st == .completed, "TaskUpdate: status") } else { check(false, "TaskUpdate") }
    if case .toolEnd(let t, _)? = dec(Fx.claude("PostToolUse", ["tool_name": "TaskUpdate", "tool_input": ["taskId": 5, "status": "deleted"]]))?.payload,
       case .delete(let id)? = t.taskMutation { eq(id, "5", "TaskUpdate: deleted becomes a delete mutation") } else { check(false, "TaskUpdate deleted") }
    if case .toolStart(let t)? = dec(Fx.claude("PreToolUse", ["tool_name": "Agent", "tool_input": ["description": "Explore", "subagent_type": "Explore"]]))?.payload { check(t.isSubagentTool, "Agent tool is flagged as a subagent tool") } else { check(false, "Agent tool") }

    section("Tolerance: renamed, missing, mistyped, extra fields")
    check(dec(["hook_event_name": "Stop"]) == nil, "no session id and no ppid: dropped")
    eq(dec(["hook_event_name": "Stop"], ppid: 77)?.sessionID ?? "nil", "pid:77", "no session id but ppid: synthetic pid key")
    eq(dec(["hookEventName": "Stop", "sessionId": "abc"])?.sessionID ?? "nil", "abc", "camelCase keys are accepted")
    check(dec(["session_id": "s1"]) == nil, "no event name: dropped")
    if case .ignored(let n)? = dec(["session_id": "s1", "hook_event_name": "Elicitation"])?.payload { eq(n, "Elicitation", "unknown event name is ignored, not an error") } else { check(false, "unknown event") }
    if case .toolStart(let t)? = dec(["session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": "{\"command\":\"echo hi\"}"])?.payload { eq(t.summary, "echo hi", "tool_input given as a JSON string is parsed") } else { check(false, "tool_input string") }
    if case .toolStart(let t)? = dec(["session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": 5])?.payload { eq(t.summary, "Bash", "tool_input of the wrong type gives the tool name") } else { check(false, "tool_input number") }
    check(dec(["session_id": 12345, "hook_event_name": "Stop"]) == nil, "numeric session_id is rejected")
    check(dec(["session_id": NSNull(), "hook_event_name": "Stop"]) == nil, "null session_id is rejected")
    if case .stop(let m)? = dec(["session_id": "s", "hook_event_name": "Stop", "last_assistant_message": 7, "extra": ["a": 1]])?.payload { check(m == nil, "wrong-typed message is ignored") } else { check(false, "stop mistyped") }
    eq(dec(["session_id": String(repeating: "x", count: 500), "hook_event_name": "Stop"])?.sessionID.count ?? 0, 128, "session id is bounded to 128")
    eq(dec(["session_id": "a\u{202E}b\u{0}c", "hook_event_name": "Stop"])?.sessionID ?? "", "abc", "session id is sanitised")
    if case .promptSubmit(let p, _)? = dec(["session_id": "s", "hook_event_name": "UserPromptSubmit", "prompt": String(repeating: "p", count: 100_000)])?.payload { check((p ?? "").count <= 200, "prompt is bounded to 200") } else { check(false, "prompt bound") }

    section("Framing line")
    eq(AgentEventDecoder.parseEnvelope(Data("{\"v\":1,\"agent\":\"claude\",\"ppid\":123}".utf8)), HookEnvelope(version: 1, agent: .claudeCode, ppid: 123), "envelope: claude")
    eq(AgentEventDecoder.parseEnvelope(Data("{\"v\":1,\"agent\":\"codex\",\"ppid\":\"55\"}".utf8))?.ppid ?? 0, 55, "envelope: ppid as a numeric string")
    check(AgentEventDecoder.parseEnvelope(Data("{\"v\":2,\"agent\":\"claude\"}".utf8)) == nil, "envelope: unknown version rejected")
    check(AgentEventDecoder.parseEnvelope(Data("{\"v\":1,\"agent\":\"gemini\"}".utf8)) == nil, "envelope: unknown agent rejected")
    check(AgentEventDecoder.parseEnvelope(Data("{\"agent\":\"claude\"}".utf8)) == nil, "envelope: missing version rejected")
    check(AgentEventDecoder.parseEnvelope(Data("not json".utf8)) == nil, "envelope: garbage rejected")
    check(AgentEventDecoder.parseEnvelope(Data("{\"v\":1,\"agent\":\"claude\",\"ppid\":-5}".utf8))?.ppid == nil, "envelope: negative ppid dropped, envelope kept")
    check(AgentEventDecoder.parseEnvelope(Data("{\"v\":1,\"agent\":\"claude\",\"pad\":\"\(String(repeating: "x", count: 5000))\"}".utf8)) == nil, "envelope: oversized line rejected")

    section("Codex hook events")
    for (name, json) in Fx.codexEvents {
        let e = decx(json)
        check(e != nil && e!.kind == .codex && e!.sessionID == Fx.codexSID, "codex \(name): decodes and keeps the thread id")
    }
    eq(decx(Fx.codexEvents[1].json)!.promptID ?? "", "turn-1", "codex: turn_id becomes promptID")
    eq(decx(Fx.codexEvents[0].json)!.model ?? "", "gpt-5-codex", "codex: model")
    if case .toolStart(let t)? = decx(Fx.codexEvents[2].json)?.payload { eq(t.summary, "ls -la", "codex PreToolUse exec_command: cmd summary") } else { check(false, "codex pre") }
    if case .toolStart(let t)? = decx(Fx.codex("PreToolUse", ["tool_name": "update_plan", "tool_input": ["plan": [["step": "A", "status": "in_progress"], ["step": "B", "status": "pending"]]]]))?.payload,
       case .replaceAll(let tasks)? = t.taskMutation {
        eq(tasks.map { $0.status }, [.inProgress, .pending], "codex update_plan: statuses")
    } else { check(false, "codex update_plan") }
    if case .toolStart(let t)? = decx(Fx.codex("PreToolUse", ["tool_name": "apply_patch", "tool_input": ["input": "*** Begin Patch\n*** Add File: z.txt\n+x"]]))?.payload { eq(t.summary, "z.txt", "codex apply_patch: path") } else { check(false, "codex apply_patch") }
    if case .permissionRequest(let info)? = decx(Fx.codexEvents[3].json)?.payload {
        eq(info.tool.name, "Bash", "codex PermissionRequest: tool"); eq(info.suggestions.count, 0, "codex PermissionRequest: no suggestions")
    } else { check(false, "codex perm") }
    if case .permissionRequest(let info)? = decx(Fx.codex("PermissionRequest", ["tool_name": "Bash", "tool_input": ["description": "Needs network"], "permission_suggestions": [["type": "setMode", "mode": "plan"]]]))?.payload {
        eq(info.suggestions.count, 0, "codex: permission_suggestions are never honoured"); check((info.tool.detail ?? "").contains("Needs network"), "codex: description is carried into the detail")
    } else { check(false, "codex perm desc") }
    if case .interrupt = decx(Fx.codexEvents[6].json)!.payload { check(true, "codex Interrupt") } else { check(false, "codex Interrupt") }
    if case .subagentStart(let id, _) = decx(Fx.codexEvents[7].json)!.payload { eq(id, "sub-9", "codex SubagentStart") } else { check(false, "codex SubagentStart") }
    check(decx(["hook_event_name": "Stop"]) == nil, "codex: no thread id and no ppid dropped")
    eq(decx(["hook_event_name": "Stop", "thread_id": "t-1"])?.sessionID ?? "nil", "t-1", "codex: thread_id alias")

    section("Codex rollout lines")
    func ev(_ i: Int) -> [AgentEvent] { CodexEvents.decodeRolloutLine(Fx.rolloutLines[i], sessionID: "R") }
    check(ev(0).first.map { if case .meta = $0.payload { return $0.cwd == Fx.cwd }; return false } ?? false, "session_meta: cwd")
    eq(ev(1).first?.model ?? "", "gpt-5-codex", "turn_context: model"); eq(ev(1).first?.permissionMode ?? "", "on-request", "turn_context: approval policy")
    check(ev(2).first.map { if case .turnStarted = $0.payload { return true }; return false } ?? false, "task_started")
    check(ev(3).first.map { if case .turnStarted = $0.payload { return true }; return false } ?? false, "turn_started")
    if case .promptSubmit(let p, _)? = ev(4).first?.payload { eq(p ?? "", "refactor the parser", "user_message") } else { check(false, "user_message") }
    if case .assistantText(let t)? = ev(5).first?.payload { eq(t, "Working on it.", "agent_message") } else { check(false, "agent_message") }
    if case .planUpdate(let tasks)? = ev(6).first?.payload { eq(tasks.map { $0.status }, [.completed, .inProgress, .pending], "plan_update statuses") } else { check(false, "plan_update") }
    for i in [7, 8, 9] { if case .approvalNeeded(let w)? = ev(i).first?.payload { eq(w ?? "", "permission prompt", "approval event \(i) waits for permission") } else { check(false, "approval \(i)") } }
    if case .approvalNeeded(let w)? = ev(10).first?.payload { eq(w ?? "", "input needed", "request_user_input waits for input") } else { check(false, "request_user_input") }
    if case .toolStart(let t)? = ev(11).first?.payload { eq(t.summary, "make", "exec_command_begin summary") } else { check(false, "exec_command_begin") }
    if case .toolEnd(_, let failed)? = ev(12).first?.payload { check(!failed, "exec_command_end ok") } else { check(false, "exec_command_end") }
    if case .toolStart(let t)? = ev(13).first?.payload { eq(t.summary, "src/a.swift", "patch_apply_begin path") } else { check(false, "patch_apply_begin") }
    if case .toolEnd(_, let failed)? = ev(14).first?.payload { check(!failed, "patch_apply_end ok") } else { check(false, "patch_apply_end") }
    if case .toolStart(let t)? = ev(15).first?.payload { eq(t.summary, "gh/pr", "mcp_tool_call_begin") } else { check(false, "mcp begin") }
    if case .usage(let u)? = ev(17).first?.payload {
        eq(u.fiveHourPercent ?? -1, 12.5, "token_count: 5 h window"); eq(u.sevenDayPercent ?? -1, 40.0, "token_count: 7 d window"); eq(u.contextUsedPercent ?? -1, 10.0, "token_count: context percent")
    } else { check(false, "token_count") }
    if case .compact(let s, _)? = ev(18).first?.payload { check(!s, "context_compacted") } else { check(false, "context_compacted") }
    check(ev(19).isEmpty, "spawn begin does not invent a child from a tool call ID")
    if case .subagentStart(let id, _)? = ev(20).first?.payload { eq(id, "child1", "spawn end means child created, not child finished") } else { check(false, "spawn end starts child") }
    if case .turnCompleted(let m)? = ev(22).first?.payload { eq(m ?? "", "All done.", "task_complete: last message") } else { check(false, "task_complete") }
    check(ev(24).first.map { if case .turnAborted = $0.payload { return true }; return false } ?? false, "turn_aborted")
    check(ev(25).first.map { if case .shutdown = $0.payload { return true }; return false } ?? false, "shutdown_complete")
    if case .planUpdate(let tasks)? = ev(26).first?.payload { eq(tasks.count, 1, "response_item update_plan") } else { check(false, "response_item update_plan") }
    if case .assistantText(let t)? = ev(27).first?.payload { eq(t, "Hello from the model", "response_item assistant message") } else { check(false, "response_item message") }
    check(CodexEvents.decodeRolloutLine(["type": "event_msg", "payload": ["type": "thread_goal_updated"]], sessionID: "R").isEmpty, "unknown event_msg type produces nothing")
    check(CodexEvents.decodeRolloutLine(["type": "weird"], sessionID: "R").isEmpty, "unknown line type produces nothing")
    check(CodexEvents.decodeRolloutLine(["type": "event_msg", "payload": "string"], sessionID: "R").isEmpty, "non-dict payload produces nothing")
    check(CodexEvents.decodeRolloutLine([:], sessionID: "R").isEmpty, "empty line produces nothing")
    check(ev(4).first?.at != nil, "rollout events carry the line timestamp")
    check(ev(4).first?.provenance == .rollout, "rollout events have rollout provenance")

    section("Claude transcript lines")
    func tl(_ o: [String: Any]) -> [AgentEvent] { ClaudeEvents.decodeTranscriptLine(o, sessionID: "T") }
    if case .titleChanged(let t)? = tl(["type": "ai-title", "aiTitle": "Fix tests"]).first?.payload { eq(t, "Fix tests", "ai-title") } else { check(false, "ai-title") }
    if case .lastPrompt(let t)? = tl(["type": "last-prompt", "lastPrompt": "hello there"]).first?.payload { eq(t, "hello there", "last-prompt") } else { check(false, "last-prompt") }
    if case .promptSubmit(let p, _)? = tl(["type": "user", "message": ["role": "user", "content": "build it"]]).first?.payload { eq(p ?? "", "build it", "user entry (string content)") } else { check(false, "user string") }
    check(tl(["type": "user", "message": ["content": "<command-name>/clear</command-name>"]]).isEmpty, "user entry: slash-command scaffolding filtered")
    check(tl(["type": "user", "isMeta": true, "message": ["content": "x"]]).isEmpty, "user entry: isMeta filtered")
    check(tl(["type": "user", "isSidechain": true, "message": ["content": "x"]]).isEmpty, "sidechain entries filtered")
    if case .toolEnd(let t, let failed)? = tl(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "tu1", "is_error": true]]]]).first?.payload { eq(t.toolUseID ?? "", "tu1", "tool_result: id"); check(failed, "tool_result: is_error") } else { check(false, "tool_result") }
    let asst = tl(["type": "assistant", "timestamp": "2026-10-21T09:00:00Z", "message": ["model": "claude-opus-4-7", "stop_reason": "end_turn", "content": [["type": "text", "text": "All set."], ["type": "tool_use", "id": "tu2", "name": "Bash", "input": ["command": "ls"]]]]])
    eq(asst.count, 3, "assistant entry: text, tool_use and end_turn")
    if case .toolStart(let t)? = asst.dropFirst().first?.payload { eq(t.summary, "ls", "assistant tool_use summary") } else { check(false, "assistant tool_use") }
    if case .stop(let m)? = asst.last?.payload { eq(m ?? "", "All set.", "assistant end_turn becomes stop") } else { check(false, "assistant stop") }
    check(tl(["type": "queue-operation"]).isEmpty, "unknown transcript types are ignored")
    check(tl(["nothing": 1]).isEmpty, "line without a type is ignored")

    section("Fuzz: 2000 random mutations never crash")
    var rng = SplitMix64(seed: 0xA7011)
    var pool: [Data] = []
    for (_, j) in Fx.claudeEvents + Fx.codexEvents { if let d = try? JSONSerialization.data(withJSONObject: j) { pool.append(d) } }
    for l in Fx.rolloutLines { if let d = try? JSONSerialization.data(withJSONObject: l) { pool.append(d) } }
    pool.append(Data("{\"v\":1,\"agent\":\"claude\",\"ppid\":99}".utf8))
    var decoded = 0, boundedOK = true
    for i in 0..<2000 {
        var d = pool[Int(rng.next() % UInt64(pool.count))]
        let ops = Int(rng.next() % 4) + 1
        for _ in 0..<ops { d = mutate(d, &rng) }
        _ = AgentEventDecoder.parseEnvelope(d)
        if let obj = JSONField.parseObject(d) {
            let m = mutateJSON(obj, &rng, depth: 0)
            for kind in [AgentKind.claudeCode, .codex] {
                let env = HookEnvelope(version: 1, agent: kind, ppid: Int32(i % 50) - 5)
                if let e = AgentEventDecoder.decode(envelope: env, body: m) {
                    decoded += 1
                    if e.sessionID.count > 128 { boundedOK = false }
                    if case .toolStart(let t) = e.payload, t.summary.count > 160 { boundedOK = false }
                }
            }
            _ = CodexEvents.decodeRolloutLine(m, sessionID: "F")
            _ = ClaudeEvents.decodeTranscriptLine(m, sessionID: "F")
            _ = DiscoveryRegistry.parseRegistryEntry((try? JSONSerialization.data(withJSONObject: m)) ?? Data())
        }
        if i % 400 == 0 { check(true, "fuzz progress \(i)") }
    }
    check(decoded > 100, "fuzz: a healthy share of mutants still decode (\(decoded))")
    check(boundedOK, "fuzz: decoded strings stay bounded")
    check(true, "fuzz: 2000 mutations completed without a crash")
    // Pathological inputs
    let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
    check(JSONField.parseObject(Data(deep.utf8)) == nil, "deeply nested JSON is rejected without crashing")
    check(JSONField.parseObject(Data()) == nil, "empty data is rejected")
    check(JSONField.parseObject(Data([0xFF, 0xFE, 0x00])) == nil, "binary garbage is rejected")
    check(AgentEventDecoder.parseEnvelope(Data(repeating: 0x7B, count: 4000)) == nil, "4000 open braces are rejected")
}

// MARK: Mutators

private func mutate(_ data: Data, _ rng: inout SplitMix64) -> Data {
    var d = [UInt8](data)
    if d.isEmpty { return Data([UInt8(truncatingIfNeeded: rng.next())]) }
    switch rng.next() % 8 {
    case 0: d[Int(rng.next() % UInt64(d.count))] = UInt8(truncatingIfNeeded: rng.next())
    case 1: let a = Int(rng.next() % UInt64(d.count)); let n = Int(rng.next() % 8) + 1; d.removeSubrange(a..<min(d.count, a + n))
    case 2: let a = Int(rng.next() % UInt64(d.count)); d.insert(contentsOf: (0..<Int(rng.next() % 6) + 1).map { _ in UInt8(truncatingIfNeeded: rng.next()) }, at: a)
    case 3: d = Array(d.prefix(Int(rng.next() % UInt64(d.count))))
    case 4: let a = Int(rng.next() % UInt64(d.count)); let b = min(d.count, a + Int(rng.next() % 32) + 1); d.insert(contentsOf: d[a..<b], at: a)
    case 5: d[Int(rng.next() % UInt64(d.count))] = [0x00, 0xFF, 0x22, 0x5C, 0x7B, 0x7D][Int(rng.next() % 6)]
    case 6: d.insert(contentsOf: Array("\u{202E}\u{200B}\u{1B}[31m".utf8), at: Int(rng.next() % UInt64(d.count)))
    default: d += Array(String(repeating: "x", count: Int(rng.next() % 5000)).utf8)
    }
    return Data(d)
}

private func mutateJSON(_ o: [String: Any], _ rng: inout SplitMix64, depth: Int) -> [String: Any] {
    var out = o
    for k in Array(o.keys) {
        guard rng.next() % 5 == 0 else {
            if let child = o[k] as? [String: Any], depth < 4 { out[k] = mutateJSON(child, &rng, depth: depth + 1) }
            continue
        }
        switch rng.next() % 7 {
        case 0: out[k] = NSNull()
        case 1: out[k] = Int(truncatingIfNeeded: rng.next())
        case 2: out[k] = [Any]()
        case 3: out[k] = ["x": ["y": [1, 2, 3]]]
        case 4: out[k] = String(repeating: "\u{202E}a", count: Int(rng.next() % 3000))
        case 5: out[k] = (rng.next() % 2 == 0)
        default: out[k] = Double.nan.isNaN ? 1e300 : 0
        }
    }
    return out
}
