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

// Codex: hook payloads (research 3.3) and rollout JSONL event_msg lines (research 3.6, INFERRED from third-party
// sources: the format is unstable, so everything is optional and unknown types are ignored).

enum CodexEvents {
    /// Hook payload -> event. Same shape as Claude's hooks with a few additions (turn_id, update_plan, Interrupt).
    static func decodeHook(_ obj: [String: Any], ppid: Int32? = nil) -> AgentEvent? {
        HookDecoding.decode(kind: .codex, obj, ppid: ppid)
    }

    static func decodeHook(data: Data, ppid: Int32? = nil) -> AgentEvent? {
        guard let obj = JSONField.parseObject(data) else { return nil }
        return decodeHook(obj, ppid: ppid)
    }

    // MARK: Rollout lines

    /// One rollout line `{timestamp, type, payload}` -> events with `.rollout` provenance.
    /// `sessionID` comes from the file name / session_meta (the rollout file is one thread).
    static func decodeRolloutLine(_ obj: [String: Any], sessionID: String) -> [AgentEvent] {
        guard let type = obj["type"] as? String else { return [] }
        let payload = (obj["payload"] as? [String: Any]) ?? [:]
        let at = JSONField.date(obj["timestamp"] as? String)
        func ev(_ p: AgentEventPayload, cwd: String? = nil, model: String? = nil, mode: String? = nil) -> AgentEvent {
            AgentEvent(kind: .codex, sessionID: sessionID, payload: p, provenance: .rollout, at: at, cwd: cwd,
                       permissionMode: mode, model: model)
        }
        switch type {
        case "session_meta":
            let cwd = AgentText.cleanOptional(JSONField.string(payload, "cwd"), max: 512)
            return [ev(.meta, cwd: cwd, model: AgentText.cleanOptional(JSONField.string(payload, "model"), max: 80))]
        case "turn_context":
            return [ev(.meta, cwd: AgentText.cleanOptional(JSONField.string(payload, "cwd"), max: 512),
                       model: AgentText.cleanOptional(JSONField.string(payload, "model"), max: 80),
                       mode: AgentText.cleanOptional(JSONField.string(payload, "approval_policy", "sandbox_policy_type"), max: 40))]
        case "event_msg":
            return decodeEventMsg(payload, ev)
        case "response_item":
            return decodeResponseItem(payload, ev)
        case "compacted":
            return [ev(.compact(isStart: false, trigger: nil))]
        default:
            return []
        }
    }

    private static func decodeEventMsg(_ p: [String: Any], _ ev: (AgentEventPayload, String?, String?, String?) -> AgentEvent) -> [AgentEvent] {
        func e(_ x: AgentEventPayload) -> AgentEvent { ev(x, nil, nil, nil) }
        guard let t = p["type"] as? String else { return [] }
        switch t {
        case "task_started", "turn_started":
            return [e(.turnStarted)]
        case "task_complete", "turn_complete":
            return [e(.turnCompleted(lastMessage: AgentText.cleanOptional(JSONField.string(p, "last_agent_message", "last_assistant_message", "message"), max: 300)))]
        case "turn_aborted":
            return [e(.turnAborted)]
        case "user_message":
            guard let m = JSONField.string(p, "message", "text").flatMap(AgentText.userFacingPrompt) else { return [] }
            return [e(.promptSubmit(prompt: m, title: nil))]
        case "agent_message":
            guard let m = AgentText.cleanOptional(JSONField.string(p, "message", "text"), max: 300) else { return [] }
            return [e(.assistantText(m))]
        case "plan_update":
            guard let plan = JSONField.array(p, "plan") else { return [] }
            return [e(.planUpdate(ToolInfoBuilder.tasks(from: plan, titleKeys: ["step", "content", "title"])))]
        case "exec_approval_request", "apply_patch_approval_request", "request_permissions":
            return [e(.approvalNeeded(waitingFor: "permission prompt"))]
        case "request_user_input":
            return [e(.approvalNeeded(waitingFor: "input needed"))]
        case "exec_command_begin":
            let cmd = AgentText.summary(tool: "exec_command", input: p)
            return [e(.toolStart(ToolInfo(name: "exec_command", summary: cmd, toolUseID: AgentText.cleanOptional(JSONField.string(p, "call_id"), max: 128))))]
        case "exec_command_end":
            let failed = (JSONField.int(p, "exit_code") ?? 0) != 0
            return [e(.toolEnd(ToolInfo(name: "exec_command", summary: "", toolUseID: AgentText.cleanOptional(JSONField.string(p, "call_id"), max: 128)), failed: failed))]
        case "patch_apply_begin":
            var s = "apply_patch"
            if let ch = p["changes"] as? [String: Any], let first = ch.keys.sorted().first { s = AgentText.shortPath(first) }
            return [e(.toolStart(ToolInfo(name: "apply_patch", summary: AgentText.clean(s, max: 160), toolUseID: AgentText.cleanOptional(JSONField.string(p, "call_id"), max: 128))))]
        case "patch_apply_end":
            let ok = JSONField.bool(p, "success") ?? true
            return [e(.toolEnd(ToolInfo(name: "apply_patch", summary: "", toolUseID: AgentText.cleanOptional(JSONField.string(p, "call_id"), max: 128)), failed: !ok))]
        case "mcp_tool_call_begin":
            var s = "mcp"
            if let inv = p["invocation"] as? [String: Any] {
                s = "\(JSONField.string(inv, "server") ?? "mcp")/\(JSONField.string(inv, "tool") ?? "tool")"
            }
            return [e(.toolStart(ToolInfo(name: "mcp", summary: AgentText.clean(s, max: 160), toolUseID: AgentText.cleanOptional(JSONField.string(p, "call_id"), max: 128))))]
        case "mcp_tool_call_end":
            return [e(.toolEnd(ToolInfo(name: "mcp", summary: "", toolUseID: AgentText.cleanOptional(JSONField.string(p, "call_id"), max: 128)), failed: false))]
        case "token_count":
            guard let u = usage(from: p) else { return [] }
            return [e(.usage(u))]
        case "context_compacted":
            return [e(.compact(isStart: false, trigger: nil))]
        case "shutdown_complete":
            return [e(.shutdown)]
        case "collab_agent_spawn_begin":
            // A spawn request is a tool call, not a child session. Wait for the real thread ID.
            return []
        case "collab_agent_spawn_end":
            guard let id = AgentText.cleanOptional(JSONField.string(p, "new_thread_id"), max: 128) else { return [] }
            let role = AgentText.cleanOptional(JSONField.string(p, "new_agent_nickname", "new_agent_role", "agent_type"), max: 64)
            let status = p["status"] as? String
            let object = p["status"] as? [String: Any] ?? [:]
            if status == "shutdown" || object["completed"] != nil { return [e(.subagentStop(id: id, type: role, lastMessage: nil, failed: false))] }
            if object["errored"] != nil || status == "not_found" { return [e(.subagentStop(id: id, type: role, lastMessage: nil, failed: true))] }
            if status == "interrupted" { return [e(.subagentIdle(id: id, type: role))] }
            return [e(.subagentStart(id: id, type: role))]
        case "sub_agent_activity":
            guard let id = AgentText.cleanOptional(JSONField.string(p, "agent_thread_id", "thread_id", "agent_id"), max: 128) else { return [] }
            return [e(.subagentStart(id: id, type: AgentText.cleanOptional(JSONField.string(p, "agent_path", "role"), max: 64)))]
        default:
            return []
        }
    }

    private static func decodeResponseItem(_ p: [String: Any], _ ev: (AgentEventPayload, String?, String?, String?) -> AgentEvent) -> [AgentEvent] {
        guard let t = p["type"] as? String else { return [] }
        switch t {
        case "function_call", "custom_tool_call":
            guard let name = p["name"] as? String, name == "update_plan",
                  let args = JSONField.dict(p, "arguments", "input"),
                  let plan = args["plan"] as? [Any] else { return [] }
            return [ev(.planUpdate(ToolInfoBuilder.tasks(from: plan, titleKeys: ["step", "content", "title"])), nil, nil, nil)]
        case "message":
            guard (p["role"] as? String) == "assistant", let content = p["content"] as? [Any] else { return [] }
            var text: String?
            for c in content.prefix(32) {
                if let d = c as? [String: Any], let s = d["text"] as? String, let cl = AgentText.cleanOptional(s, max: 300) { text = cl }
            }
            guard let tx = text else { return [] }
            return [ev(.assistantText(tx), nil, nil, nil)]
        default:
            return []
        }
    }

    /// token_count payload -> usage. Rate limits: primary ~ 5 h window, secondary ~ 7 d window (classified by window_minutes).
    static func usage(from p: [String: Any]) -> UsageSnapshot? {
        var snap = UsageSnapshot(source: "codex rollout")
        var any = false
        if let info = p["info"] as? [String: Any] {
            let window = JSONField.double(info, "model_context_window")
            if let last = info["last_token_usage"] as? [String: Any], let total = JSONField.double(last, "total_tokens"),
               let w = window, w > 0 {
                snap.contextUsedPercent = min(100, max(0, total / w * 100)); any = true
            }
        }
        if let rl = p["rate_limits"] as? [String: Any] {
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any], let used = JSONField.double(w, "used_percent", "usedPercent") else { continue }
                let mins = JSONField.double(w, "window_minutes", "windowDurationMins") ?? (key == "primary" ? 300 : 10080)
                let pct = min(100, max(0, used))
                if mins <= 600 { snap.fiveHourPercent = pct } else { snap.sevenDayPercent = pct }
                any = true
            }
        }
        return any ? snap : nil
    }
}
