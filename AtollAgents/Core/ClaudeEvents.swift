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

// Tolerant decoder: hook stdin JSON (docs/AI-AGENTS-RESEARCH.md 2.2) -> AgentEvent.
// Field names are high-confidence but NOT byte-exact, so every accessor tolerates missing, extra, renamed or
// wrongly-typed fields. Nothing in here may crash on malformed input.

// MARK: - Tool info and task extraction (shared by Claude and Codex)

enum ToolInfoBuilder {
    static func make(name rawName: String, input: [String: Any]?, response: Any? = nil, toolUseID: String? = nil,
                     durationMS: Int? = nil, error: String? = nil, withDetail: Bool = false) -> ToolInfo {
        let name = AgentText.displayTool(rawName)
        var info = ToolInfo(name: name, summary: AgentText.summary(tool: rawName, input: input),
                            detail: withDetail ? AgentText.detail(tool: rawName, input: input) : nil,
                            toolUseID: AgentText.cleanOptional(toolUseID, max: 128),
                            isSubagentTool: rawName == "Agent" || rawName == "Task",
                            errorText: AgentText.cleanOptional(error, max: 300), durationMS: durationMS)
        info.taskMutation = taskMutation(tool: rawName, input: input ?? [:], response: response)
        if info.isSubagentTool, let r = response as? [String: Any] {
            if let id = JSONField.nonEmptyString(r, "agentId", "agent_id") { info.spawnedAgentID = AgentText.cleanOptional(id, max: 128) }
        }
        return info
    }

    static func mapStatus(_ raw: String?) -> TaskStatus? {
        guard let raw = raw else { return nil }
        let s = raw.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch s {
        case "pending", "todo", "queued", "open", "not_started": return .pending
        case "in_progress", "inprogress", "active", "running", "started": return .inProgress
        case "completed", "complete", "done", "finished": return .completed
        case "cancelled", "canceled", "deleted", "skipped": return .cancelled
        default: return nil
        }
    }

    static func tasks(from array: [Any], titleKeys: [String], idKeys: [String] = ["id", "taskId", "task_id"]) -> [AgentTask] {
        var out: [AgentTask] = []
        for (i, item) in array.prefix(200).enumerated() {
            guard let d = item as? [String: Any] else {
                if let s = item as? String, let t = AgentText.cleanOptional(s, max: 200) {
                    out.append(AgentTask(id: "t\(i + 1)", title: t, status: .pending, order: i))
                }
                continue
            }
            var title: String?
            for k in titleKeys { if let s = d[k] as? String, let t = AgentText.cleanOptional(s, max: 200) { title = t; break } }
            guard let t = title else { continue }
            var id = "t\(i + 1)"
            for k in idKeys {
                if let s = d[k] as? String, let c = AgentText.cleanOptional(s, max: 64) { id = c; break }
                if let n = d[k] as? NSNumber { id = n.stringValue; break }
            }
            let status = mapStatus(d["status"] as? String) ?? .pending
            let active = AgentText.cleanOptional(d["activeForm"] as? String ?? d["active_form"] as? String, max: 200)
            out.append(AgentTask(id: id, title: t, status: status, activeForm: active, order: i))
        }
        return out
    }

    static func taskMutation(tool: String, input: [String: Any], response: Any?) -> TaskMutation? {
        switch tool {
        case "TodoWrite":
            guard let todos = input["todos"] as? [Any] else { return nil }
            return .replaceAll(tasks(from: todos, titleKeys: ["content", "subject", "title"]))
        case "update_plan":
            guard let plan = input["plan"] as? [Any] else { return nil }
            return .replaceAll(tasks(from: plan, titleKeys: ["step", "content", "title"]))
        case "TaskCreate":
            guard let title = AgentText.cleanOptional(JSONField.string(input, "subject", "title", "content"), max: 200) else { return nil }
            let id = extractTaskID(response) ?? ""
            let active = AgentText.cleanOptional(JSONField.string(input, "activeForm", "active_form"), max: 200)
            return .create(AgentTask(id: id, title: title, status: .pending, activeForm: active))
        case "TaskUpdate":
            var id: String?
            for k in ["taskId", "task_id", "id"] {
                if let s = input[k] as? String, let c = AgentText.cleanOptional(s, max: 64) { id = c; break }
                if let n = input[k] as? NSNumber { id = n.stringValue; break }
            }
            guard let tid = id else { return nil }
            let rawStatus = (input["status"] as? String)?.lowercased()
            if rawStatus == "deleted" { return .delete(id: tid) }
            return .update(id: tid, status: mapStatus(rawStatus),
                           title: AgentText.cleanOptional(JSONField.string(input, "subject", "title"), max: 200),
                           activeForm: AgentText.cleanOptional(JSONField.string(input, "activeForm", "active_form"), max: 200))
        default:
            return nil
        }
    }

    /// TaskCreate's response is documented loosely: accept a dict, a string ("Task #3 created"), or content blocks.
    static func extractTaskID(_ response: Any?, depth: Int = 0) -> String? {
        guard depth < 4, let response = response else { return nil }
        if let d = response as? [String: Any] {
            for k in ["taskId", "task_id", "id"] {
                if let s = d[k] as? String, !s.isEmpty, s.count <= 64 { return AgentText.cleanOptional(s, max: 64) }
                if let n = d[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
            }
            for k in ["task", "result", "content", "output"] {
                if let v = d[k], let id = extractTaskID(v, depth: depth + 1) { return id }
            }
            return nil
        }
        if let a = response as? [Any] {
            for item in a.prefix(8) { if let id = extractTaskID(item, depth: depth + 1) { return id } }
            return nil
        }
        if let s = response as? String {
            let text = String(s.prefix(2000))
            if let r = text.range(of: "#[0-9]+", options: .regularExpression) { return String(text[r].dropFirst()) }
            if let r = text.range(of: "[Tt]ask[ _-]?(id)?[: ]+[0-9A-Za-z_-]+", options: .regularExpression) {
                let tok = text[r].split(whereSeparator: { $0 == " " || $0 == ":" }).last.map(String.init)
                if let tok = tok, tok.lowercased() != "id" { return AgentText.cleanOptional(tok, max: 64) }
            }
        }
        return nil
    }
}

// MARK: - Permission suggestions

enum SuggestionParser {
    static let destinations: Set<String> = ["session", "localSettings", "projectSettings", "userSettings"]
    static let safeModes: Set<String> = ["default", "acceptEdits", "plan", "auto", "dontAsk"]

    /// Validates the agent's own suggestions. Returns offered labels (id = original index) and sanitised JSON entries
    /// (Data() for entries that are not offered). Only entry kinds that are safe to echo back are offered.
    static func parse(_ raw: Any?) -> (suggestions: [PermissionSuggestion], entries: [Data]) {
        guard let arr = raw as? [Any] else { return ([], []) }
        var suggestions: [PermissionSuggestion] = []
        var entries: [Data] = []
        for (i, item) in arr.prefix(8).enumerated() {
            guard let d = item as? [String: Any], let (label, clean) = sanitise(d),
                  JSONSerialization.isValidJSONObject(clean),
                  let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]) else {
                entries.append(Data()); continue
            }
            suggestions.append(PermissionSuggestion(id: i, label: label))
            entries.append(data)
        }
        return (suggestions, entries)
    }

    private static func sanitise(_ d: [String: Any]) -> (String, [String: Any])? {
        guard let type = d["type"] as? String else { return nil }
        var out: [String: Any] = ["type": type]
        var dest: String?
        if let ds = d["destination"] as? String, destinations.contains(ds) { out["destination"] = ds; dest = ds }
        switch type {
        case "addRules":
            guard (d["behavior"] as? String) == "allow", let rules = d["rules"] as? [Any], !rules.isEmpty else { return nil }
            var clean: [[String: Any]] = []
            var names: [String] = []
            for r in rules.prefix(8) {
                guard let rd = r as? [String: Any], let tn = AgentText.cleanOptional(rd["toolName"] as? String, max: 200) else { return nil }
                var e: [String: Any] = ["toolName": tn]
                var shown = tn
                if let rc = rd["ruleContent"] as? String, !rc.isEmpty {
                    let c = AgentText.clean(rc, max: 1000)
                    e["ruleContent"] = c
                    shown = "\(tn)(\(AgentText.clean(c, max: 60)))"
                }
                clean.append(e); names.append(shown)
            }
            out["rules"] = clean
            out["behavior"] = "allow"
            var label = (dest == "session" ? "Allow " : "Always allow ") + names.prefix(3).joined(separator: ", ")
            if names.count > 3 { label += " (+\(names.count - 3) more)" }
            if dest == "session" { label += " for this session" }
            return (AgentText.clean(label, max: 160), out)
        case "addDirectories":
            guard let dirs = d["directories"] as? [Any], !dirs.isEmpty else { return nil }
            let clean = dirs.prefix(8).compactMap { AgentText.cleanOptional($0 as? String, max: 512) }
            guard !clean.isEmpty else { return nil }
            out["directories"] = clean
            return (AgentText.clean("Allow access to " + AgentText.shortPath(clean[0], max: 80), max: 160), out)
        case "setMode":
            guard let m = d["mode"] as? String, safeModes.contains(m) else { return nil }
            out["mode"] = m
            return ("Switch to \(m) mode", out)
        default:
            return nil
        }
    }
}

// MARK: - Shared hook decoder

enum HookDecoding {
    static func normalizedName(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func sessionID(_ obj: [String: Any], ppid: Int32?) -> String? {
        for k in ["session_id", "sessionId", "thread_id", "thread-id", "threadId", "conversation_id"] {
            if let s = obj[k] as? String {
                let c = AgentText.clean(s, max: 128)
                if !c.isEmpty { return c }
            }
        }
        if let p = ppid, p > 1 { return "pid:\(p)" }
        return nil
    }

    static func decode(kind: AgentKind, _ obj: [String: Any], ppid: Int32?) -> AgentEvent? {
        guard let rawName = JSONField.string(obj, "hook_event_name", "hookEventName", "event", "hook_event", "type"),
              let sid = sessionID(obj, ppid: ppid) else { return nil }
        let name = normalizedName(rawName)

        var ev = AgentEvent(kind: kind, sessionID: sid, payload: .ignored(AgentText.clean(rawName, max: 64)), provenance: .hook, pid: ppid)
        ev.cwd = AgentText.cleanOptional(JSONField.string(obj, "cwd"), max: 512)
        ev.transcriptPath = AgentText.cleanOptional(JSONField.string(obj, "transcript_path", "transcriptPath"), max: 1024)
        ev.permissionMode = AgentText.cleanOptional(JSONField.string(obj, "permission_mode", "permissionMode"), max: 40)
        ev.model = AgentText.cleanOptional(JSONField.string(obj, "model"), max: 80)
            ?? AgentText.cleanOptional((obj["model"] as? [String: Any]).flatMap { JSONField.string($0, "id", "display_name") }, max: 80)
        ev.agentID = AgentText.cleanOptional(JSONField.string(obj, "agent_id", "agentId"), max: 128)
        ev.agentType = AgentText.cleanOptional(JSONField.string(obj, "agent_type", "agentType"), max: 64)
        ev.promptID = AgentText.cleanOptional(JSONField.string(obj, "prompt_id", "turn_id", "turnId"), max: 128)

        func toolInput() -> [String: Any]? { JSONField.dict(obj, "tool_input", "toolInput", "input") }
        func toolName() -> String { JSONField.string(obj, "tool_name", "toolName", "tool") ?? "" }
        func tool(withDetail: Bool, includeResponse: Bool = false, error: String? = nil) -> ToolInfo {
            ToolInfoBuilder.make(name: toolName().isEmpty ? "tool" : toolName(), input: toolInput(),
                                 response: includeResponse ? (obj["tool_response"] ?? obj["toolResponse"] ?? obj["tool_output"]) : nil,
                                 toolUseID: JSONField.string(obj, "tool_use_id", "toolUseId", "call_id"),
                                 durationMS: JSONField.int(obj, "duration_ms", "durationMs"),
                                 error: error, withDetail: withDetail)
        }

        switch name {
        case "sessionstart":
            ev.payload = .sessionStart(source: AgentText.cleanOptional(JSONField.string(obj, "source"), max: 32),
                                       title: AgentText.cleanOptional(JSONField.string(obj, "session_title", "sessionTitle"), max: 120))
        case "sessionend":
            ev.payload = .sessionEnd(reason: AgentText.cleanOptional(JSONField.string(obj, "reason"), max: 40))
        case "userpromptsubmit":
            ev.payload = .promptSubmit(prompt: AgentText.cleanOptional(JSONField.string(obj, "prompt"), max: 200),
                                       title: AgentText.cleanOptional(JSONField.string(obj, "session_title", "sessionTitle"), max: 120))
        case "pretooluse":
            ev.payload = .toolStart(tool(withDetail: false))
        case "posttooluse":
            // Codex has no failure event; a non-zero exit code / error field in the response marks failure when present.
            var failed = false
            var err: String?
            if let r = (obj["tool_response"] ?? obj["toolResponse"]) as? [String: Any] {
                if let e = r["error"] as? String, !e.isEmpty { failed = true; err = e }
                if JSONField.bool(r, "is_error", "isError") == true { failed = true }
            }
            ev.payload = .toolEnd(tool(withDetail: false, includeResponse: true, error: err), failed: failed)
        case "posttoolusefailure":
            let err = JSONField.string(obj, "error", "error_message") ?? ((obj["tool_response"] as? [String: Any]).flatMap { JSONField.string($0, "error") })
            ev.payload = .toolEnd(tool(withDetail: false, error: err), failed: true)
        case "permissionrequest":
            let t = tool(withDetail: true)
            let (sugg, entries) = kind == .claudeCode ? SuggestionParser.parse(obj["permission_suggestions"] ?? obj["permissionSuggestions"]) : ([], [])
            var info = PermissionInfo(tool: t, mcpServer: AgentText.cleanOptional(JSONField.string(obj, "mcp_server", "mcpServer"), max: 80),
                                      suggestions: sugg, suggestionEntries: entries)
            // Codex puts a human description inside tool_input; use it as detail when nothing better exists.
            if info.tool.detail == nil, let inp = toolInput(), let d = JSONField.nonEmptyString(inp, "description", "reason") {
                info.tool.detail = AgentText.cleanOptional(d, max: 600, multiline: true)
            }
            ev.payload = .permissionRequest(info)
        case "permissiondenied":
            ev.payload = .permissionDenied(tool: AgentText.cleanOptional(JSONField.string(obj, "tool_name", "toolName"), max: 64),
                                           reason: AgentText.cleanOptional(JSONField.string(obj, "reason", "message"), max: 200))
        case "notification":
            let msg = AgentText.cleanOptional(JSONField.string(obj, "message"), max: 300)
            ev.payload = .notification(notificationKind(JSONField.string(obj, "notification_type", "notificationType"), message: msg),
                                       message: msg, title: AgentText.cleanOptional(JSONField.string(obj, "title"), max: 120))
        case "stop":
            ev.payload = .stop(lastMessage: AgentText.cleanOptional(JSONField.string(obj, "last_assistant_message", "lastAssistantMessage"), max: 300))
        case "stopfailure":
            ev.payload = .stopFailure(error: AgentText.cleanOptional(JSONField.string(obj, "error", "error_type", "error_message"), max: 80) ?? "error")
        case "interrupt":
            ev.payload = .interrupt
        case "subagentstart":
            if let id = ev.agentID {
                ev.payload = .subagentStart(id: id, type: ev.agentType)
                ev.agentID = nil
            }
        case "teammateidle":
            if let id = ev.agentID ?? JSONField.string(obj, "teammate_name") {
                ev.payload = .subagentIdle(id: AgentText.clean(id, max: 128), type: ev.agentType)
                ev.agentID = nil
            }
        case "subagentstop":
            if let id = ev.agentID {
                ev.payload = .subagentStop(id: id, type: ev.agentType,
                                           lastMessage: AgentText.cleanOptional(JSONField.string(obj, "last_assistant_message", "lastAssistantMessage"), max: 300),
                                           failed: false)
                ev.agentID = nil
            }
        case "taskcreated":
            let id = AgentText.cleanOptional(JSONField.string(obj, "task_id", "taskId"), max: 64) ?? (JSONField.int(obj, "task_id", "taskId").map(String.init))
            if let id = id {
                ev.payload = .taskCreated(id: id, subject: AgentText.clean(JSONField.string(obj, "task_subject", "subject", "taskSubject") ?? "Task \(id)", max: 200),
                                          description: AgentText.cleanOptional(JSONField.string(obj, "task_description", "description"), max: 300))
            }
        case "taskcompleted":
            let id = AgentText.cleanOptional(JSONField.string(obj, "task_id", "taskId"), max: 64) ?? (JSONField.int(obj, "task_id", "taskId").map(String.init))
            if let id = id {
                ev.payload = .taskCompleted(id: id, subject: AgentText.cleanOptional(JSONField.string(obj, "task_subject", "subject"), max: 200))
            }
        case "precompact":
            ev.payload = .compact(isStart: true, trigger: AgentText.cleanOptional(JSONField.string(obj, "trigger"), max: 20))
        case "postcompact":
            ev.payload = .compact(isStart: false, trigger: AgentText.cleanOptional(JSONField.string(obj, "trigger"), max: 20))
        default:
            break
        }
        return ev
    }

    static func notificationKind(_ type: String?, message: String?) -> NotificationKind {
        if let t = type?.lowercased() {
            switch t {
            case "permission_prompt": return .permissionPrompt
            case "idle_prompt": return .idlePrompt
            case "agent_needs_input": return .agentNeedsInput
            case "agent_completed": return .agentCompleted
            case "auth_success": return .authSuccess
            case "elicitation_dialog", "elicitation_url_dialog": return .elicitation
            default: return .other(AgentText.clean(t, max: 40))
            }
        }
        // No type: fall back to the message wording Claude Code uses.
        let m = (message ?? "").lowercased()
        if m.contains("permission") { return .permissionPrompt }
        if m.contains("waiting for your input") || m.contains("needs your input") { return .idlePrompt }
        return .other("")
    }
}

// MARK: - Claude Code

enum ClaudeEvents {
    /// Decodes one hook payload. nil when the payload cannot be attributed to a session.
    static func decode(_ obj: [String: Any], ppid: Int32? = nil) -> AgentEvent? {
        HookDecoding.decode(kind: .claudeCode, obj, ppid: ppid)
    }

    static func decode(data: Data, ppid: Int32? = nil) -> AgentEvent? {
        guard let obj = JSONField.parseObject(data) else { return nil }
        return decode(obj, ppid: ppid)
    }

    /// Transcript line (`~/.claude/projects/<slug>/<id>.jsonl`) -> events with `.transcript` provenance.
    /// The format is internal and changes between versions: dispatch on "type", ignore anything unknown.
    static func decodeTranscriptLine(_ obj: [String: Any], sessionID: String, includeSidechain: Bool = false) -> [AgentEvent] {
        guard let type = obj["type"] as? String else { return [] }
        if !includeSidechain, JSONField.bool(obj, "isSidechain") == true { return [] }
        let at = JSONField.date(obj["timestamp"] as? String)
        let cwd = AgentText.cleanOptional(JSONField.string(obj, "cwd"), max: 512)
        func ev(_ p: AgentEventPayload, model: String? = nil) -> AgentEvent {
            AgentEvent(kind: .claudeCode, sessionID: sessionID, payload: p, provenance: .transcript, at: at, cwd: cwd, model: model)
        }
        switch type {
        case "ai-title", "custom-title", "summary", "title":
            let t = JSONField.nonEmptyString(obj, "aiTitle", "customTitle", "title", "summary")
            if let t = AgentText.cleanOptional(t, max: 120) { return [ev(.titleChanged(t))] }
            return []
        case "last-prompt":
            if let p = AgentText.cleanOptional(JSONField.string(obj, "lastPrompt", "prompt"), max: 200) { return [ev(.lastPrompt(p))] }
            return []
        case "user":
            if JSONField.bool(obj, "isMeta") == true { return [] }
            guard let msg = obj["message"] as? [String: Any] else { return [] }
            var out: [AgentEvent] = []
            if let s = msg["content"] as? String {
                if let p = userPrompt(s) { out.append(ev(.promptSubmit(prompt: p, title: nil))) }
            } else if let items = msg["content"] as? [Any] {
                var texts: [String] = []
                for it in items.prefix(64) {
                    guard let d = it as? [String: Any], let t = d["type"] as? String else { continue }
                    if t == "tool_result" {
                        let id = AgentText.cleanOptional(d["tool_use_id"] as? String, max: 128)
                        let failed = JSONField.bool(d, "is_error") ?? false
                        out.append(ev(.toolEnd(ToolInfo(name: "tool", summary: "", toolUseID: id), failed: failed)))
                    } else if t == "text", let s = d["text"] as? String { texts.append(s) }
                }
                if out.isEmpty, let p = userPrompt(texts.joined(separator: "\n")) { out.append(ev(.promptSubmit(prompt: p, title: nil))) }
            }
            return out
        case "assistant":
            guard let msg = obj["message"] as? [String: Any] else { return [] }
            let model = AgentText.cleanOptional(JSONField.string(msg, "model"), max: 80)
            var out: [AgentEvent] = []
            var lastText: String?
            if let items = msg["content"] as? [Any] {
                for it in items.prefix(64) {
                    guard let d = it as? [String: Any], let t = d["type"] as? String else { continue }
                    if t == "text", let s = d["text"] as? String, let c = AgentText.cleanOptional(s, max: 300) {
                        lastText = c
                        out.append(ev(.assistantText(c), model: model))
                    } else if t == "tool_use", let n = d["name"] as? String {
                        let input = d["input"] as? [String: Any]
                        out.append(ev(.toolStart(ToolInfoBuilder.make(name: n, input: input, toolUseID: d["id"] as? String)), model: model))
                    }
                }
            } else if let s = msg["content"] as? String, let c = AgentText.cleanOptional(s, max: 300) {
                lastText = c
                out.append(ev(.assistantText(c), model: model))
            }
            if let sr = msg["stop_reason"] as? String, sr == "end_turn" || sr == "stop_sequence" || sr == "max_tokens" {
                out.append(ev(.stop(lastMessage: lastText), model: model))
            }
            if out.isEmpty, model != nil { out.append(ev(.meta, model: model)) }
            return out
        default:
            return []
        }
    }

    /// Filters out slash-command scaffolding and system reminders that Claude writes as "user" entries.
    static func userPrompt(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        for p in ["<command-name>", "<command-message>", "<local-command", "<system-reminder>", "Caveat:", "[Request interrupted", "<user-prompt-submit-hook>", "<bash-"] where t.hasPrefix(p) {
            return nil
        }
        return AgentText.userFacingPrompt(t)
    }
}

// MARK: - Framing line

enum AgentEventDecoder {
    /// `{"v":1,"agent":"claude|codex","ppid":N}`. nil for anything else.
    static func parseEnvelope(_ line: Data) -> HookEnvelope? {
        guard line.count <= 4096, let o = JSONField.parseObject(line) else { return nil }
        guard let v = JSONField.int(o, "v"), v >= 1, v <= 1 else { return nil }
        guard let a = JSONField.string(o, "agent"), let kind = AgentKind(rawValue: a.lowercased()) else { return nil }
        var ppid: Int32?
        if let p = JSONField.int(o, "ppid"), p > 1, p <= Int(Int32.max) { ppid = Int32(p) }
        return HookEnvelope(version: v, agent: kind, ppid: ppid)
    }

    static func decode(envelope: HookEnvelope, body: [String: Any]) -> AgentEvent? {
        switch envelope.agent {
        case .claudeCode: return ClaudeEvents.decode(body, ppid: envelope.ppid)
        case .codex: return CodexEvents.decodeHook(body, ppid: envelope.ppid)
        }
    }
}
