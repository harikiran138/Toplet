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

// Normalised events: what the Claude/Codex decoders produce and what SessionReducer consumes.
// All strings inside are already sanitised (see AgentText). Pure values, Sendable.

/// How a task list changes, extracted from TodoWrite / TaskCreate / TaskUpdate / update_plan tool inputs.
enum TaskMutation: Equatable, Sendable {
    case replaceAll([AgentTask])
    case create(AgentTask)                       // id may be empty: the reducer assigns one
    case update(id: String, status: TaskStatus?, title: String?, activeForm: String?)
    case delete(id: String)
}

struct ToolInfo: Equatable, Sendable {
    var name: String                             // sanitised, <= 64
    var summary: String                          // one line, <= 160
    var detail: String?
    var toolUseID: String?
    var taskMutation: TaskMutation?
    var spawnedAgentID: String?                  // Agent/Task tool result naming the subagent, when present
    var isSubagentTool: Bool
    var errorText: String?
    var durationMS: Int?

    init(name: String, summary: String, detail: String? = nil, toolUseID: String? = nil, taskMutation: TaskMutation? = nil,
         spawnedAgentID: String? = nil, isSubagentTool: Bool = false, errorText: String? = nil, durationMS: Int? = nil) {
        self.name = name; self.summary = summary; self.detail = detail; self.toolUseID = toolUseID
        self.taskMutation = taskMutation; self.spawnedAgentID = spawnedAgentID; self.isSubagentTool = isSubagentTool
        self.errorText = errorText; self.durationMS = durationMS
    }
}

struct PermissionInfo: Equatable, Sendable {
    var tool: ToolInfo
    var mcpServer: String?
    /// Offered suggestions (validated). `id` is the index into the agent's own list.
    var suggestions: [PermissionSuggestion]
    /// The agent's own sanitised suggestion entries, JSON-encoded, indexed like the agent's list (empty Data = not offered).
    /// Used server-side only to build `updatedPermissions` for allowAlways. Never shown, never client text.
    var suggestionEntries: [Data]
}

enum NotificationKind: Equatable, Sendable {
    case permissionPrompt
    case idlePrompt
    case agentNeedsInput
    case agentCompleted
    case authSuccess
    case elicitation
    case other(String)
}

enum AgentEventPayload: Equatable, Sendable {
    case sessionStart(source: String?, title: String?)
    case sessionEnd(reason: String?)
    case promptSubmit(prompt: String?, title: String?)
    case toolStart(ToolInfo)
    case toolEnd(ToolInfo, failed: Bool)
    case permissionRequest(PermissionInfo)
    case permissionDenied(tool: String?, reason: String?)
    case notification(NotificationKind, message: String?, title: String?)
    case stop(lastMessage: String?)
    case stopFailure(error: String?)
    case interrupt
    case subagentIdle(id: String, type: String?)
    case subagentStart(id: String, type: String?)
    case subagentStop(id: String, type: String?, lastMessage: String?, failed: Bool)
    case taskCreated(id: String, subject: String, description: String?)
    case taskCompleted(id: String, subject: String?)
    case compact(isStart: Bool, trigger: String?)
    case planUpdate([AgentTask])
    case turnStarted
    case turnCompleted(lastMessage: String?)
    case turnAborted
    case shutdown
    /// Rollout-derived inference (read-only): the agent is waiting for a permission/answer in its own UI.
    case approvalNeeded(waitingFor: String?)
    /// An approval ended. allowed: true/false = decided in Atoll, nil = decided elsewhere / timed out / closed.
    case approvalResolved(allowed: Bool?)
    case usage(UsageSnapshot)
    case assistantText(String)
    case lastPrompt(String)                      // sets lastPrompt only (does not imply a running turn)
    case titleChanged(String)
    /// Metadata only (cwd, model, mode): applies the common fields and nothing else.
    case meta
    /// Known but irrelevant event name; kept for diagnostics/tests.
    case ignored(String)
}

struct AgentEvent: Equatable, Sendable {
    var kind: AgentKind
    var sessionID: String
    var at: Date?                                // event time when the source has one (rollout lines); nil = "now"
    var cwd: String?
    var transcriptPath: String?
    var permissionMode: String?
    var model: String?
    var agentID: String?                         // set when the event originates inside a subagent
    var agentType: String?
    var promptID: String?                        // Claude prompt_id / Codex turn_id
    var pid: Int32?                              // from the framing line's ppid (the agent process, INFERRED)
    var provenance: Provenance
    var payload: AgentEventPayload

    init(kind: AgentKind, sessionID: String, payload: AgentEventPayload, provenance: Provenance = .hook, at: Date? = nil,
         cwd: String? = nil, transcriptPath: String? = nil, permissionMode: String? = nil, model: String? = nil,
         agentID: String? = nil, agentType: String? = nil, promptID: String? = nil, pid: Int32? = nil) {
        self.kind = kind; self.sessionID = sessionID; self.payload = payload; self.provenance = provenance; self.at = at
        self.cwd = cwd; self.transcriptPath = transcriptPath; self.permissionMode = permissionMode; self.model = model
        self.agentID = agentID; self.agentType = agentType; self.promptID = promptID; self.pid = pid
    }

    var key: SessionKey { SessionKey(kind: kind, id: sessionID) }
}

/// The first line of every connection: `{"v":1,"agent":"claude|codex","ppid":N}`.
struct HookEnvelope: Equatable, Sendable {
    var version: Int
    var agent: AgentKind
    var ppid: Int32?
}

// MARK: - Tolerant JSON accessors

enum JSONField {
    static func string(_ o: [String: Any], _ keys: String...) -> String? {
        for k in keys { if let s = o[k] as? String { return s } }
        return nil
    }
    static func nonEmptyString(_ o: [String: Any], _ keys: String...) -> String? {
        for k in keys { if let s = o[k] as? String, !s.isEmpty { return s } }
        return nil
    }
    /// Ints that may arrive as numbers or numeric strings.
    static func int(_ o: [String: Any], _ keys: String...) -> Int? {
        for k in keys {
            if let n = o[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                let d = n.doubleValue
                if d.isFinite, abs(d) < 9e15 { return Int(d) }
            }
            if let s = o[k] as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        }
        return nil
    }
    static func double(_ o: [String: Any], _ keys: String...) -> Double? {
        for k in keys {
            if let n = o[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { let d = n.doubleValue; if d.isFinite { return d } }
            if let s = o[k] as? String, let d = Double(s), d.isFinite { return d }
        }
        return nil
    }
    static func bool(_ o: [String: Any], _ keys: String...) -> Bool? {
        for k in keys {
            if let b = o[k] as? Bool { return b }
            if let s = o[k] as? String { if s == "true" { return true }; if s == "false" { return false } }
        }
        return nil
    }
    static func dict(_ o: [String: Any], _ keys: String...) -> [String: Any]? {
        for k in keys {
            if let d = o[k] as? [String: Any] { return d }
            if let s = o[k] as? String, s.utf8.count < 1 << 20, s.hasPrefix("{"),
               let data = s.data(using: .utf8),
               let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return d }
        }
        return nil
    }
    static func array(_ o: [String: Any], _ keys: String...) -> [Any]? {
        for k in keys { if let a = o[k] as? [Any] { return a } }
        return nil
    }
    static func parseObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, let o = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return nil }
        return o
    }
    /// ISO-8601 with or without fractional seconds.
    static func date(_ s: String?) -> Date? {
        guard let s = s, s.count < 64 else { return nil }
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
