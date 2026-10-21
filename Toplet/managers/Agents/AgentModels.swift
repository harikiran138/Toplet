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

// Normalised model for AI coding agents (Claude Code, Codex). Pure value types, no UI, no AppKit.
// Design: docs/AI-AGENTS-RESEARCH.md section 6. Everything here is DISPLAY data from an untrusted local
// process: it is truncated/sanitised before it reaches these types (see AgentText).

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude"
    case codex = "codex"
    public var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
}

public enum SessionStatus: String, Codable, Sendable {
    case starting, running, waitingInput, needsPermission, idle, done, failed, stopped, unknown
    /// Sessions the user probably wants to see first.
    public var needsAttention: Bool { self == .needsPermission || self == .waitingInput || self == .failed }
}

public enum Surface: String, Codable, Sendable { case terminal, vscode, jetbrains, desktopApp, xcode, headless, background, unknown }

/// Where a fact came from. The strongest provenance wins per field (hook > appServer > registry > rollout/transcript > processScan).
public enum Provenance: Int, Codable, Sendable, Comparable {
    case processScan = 0, transcript, rollout, registry, appServer, hook
    public static func < (a: Provenance, b: Provenance) -> Bool { a.rawValue < b.rawValue }
}

public struct SessionKey: Hashable, Codable, Sendable {
    public let kind: AgentKind
    public let id: String                      // Claude session_id / Codex thread id
    public init(kind: AgentKind, id: String) { self.kind = kind; self.id = id }
}

public struct ToolActivity: Codable, Sendable, Equatable {
    public var name: String
    public var summary: String                 // short, sanitised ("npm test", "Edit Package.swift")
    public var startedAt: Date
    public var toolUseID: String?
    public init(name: String, summary: String, startedAt: Date, toolUseID: String? = nil) {
        self.name = name; self.summary = summary; self.startedAt = startedAt; self.toolUseID = toolUseID
    }
}

public enum TaskStatus: String, Codable, Sendable { case pending, inProgress, completed, cancelled }

public struct AgentTask: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var status: TaskStatus
    public var activeForm: String?
    public var order: Int
    public init(id: String, title: String, status: TaskStatus, activeForm: String? = nil, order: Int = 0) {
        self.id = id; self.title = title; self.status = status; self.activeForm = activeForm; self.order = order
    }
}

public enum SubagentStatus: String, Codable, Sendable { case running, idle, waiting, done, failed }

public struct Subagent: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var type: String?
    public var status: SubagentStatus
    public var startedAt: Date
    public var currentTool: ToolActivity?
    public var lastText: String?
    public init(id: String, type: String? = nil, status: SubagentStatus = .running, startedAt: Date = Date(),
                currentTool: ToolActivity? = nil, lastText: String? = nil) {
        self.id = id; self.type = type; self.status = status; self.startedAt = startedAt
        self.currentTool = currentTool; self.lastText = lastText
    }
}

public enum JumpTarget: Codable, Sendable, Equatable {
    case terminal(bundleID: String, tty: String?)       // Terminal.app / iTerm2 / Ghostty ... matched by tty or cwd
    case tmux(target: String, clientBundleID: String?)  // session:window.pane
    case deepLink(URL)                                  // codex://threads/<id>
    case app(bundleID: String)                          // just activate the app (VS Code, Cursor, desktop apps)
}

public struct PermissionSuggestion: Codable, Sendable, Equatable, Identifiable {
    public var id: Int                         // index in the agent's list
    public var label: String                   // e.g. "Always allow Bash(npm test:*)"
    public init(id: Int, label: String) { self.id = id; self.label = label }
}

public struct PendingApproval: Identifiable, Sendable, Equatable {
    public let id: UUID                        // server-generated, bound to ONE open connection; never client-supplied
    public var sessionKey: SessionKey
    public var agentID: String?                // set when the request comes from a subagent
    public var tool: String
    public var summary: String                 // one line, sanitised
    public var detail: String?                 // longer sanitised preview (command, file path, diff head)
    public var suggestions: [PermissionSuggestion]
    public var createdAt: Date
    public var expiresAt: Date
    public init(id: UUID = UUID(), sessionKey: SessionKey, agentID: String? = nil, tool: String, summary: String,
                detail: String? = nil, suggestions: [PermissionSuggestion] = [], createdAt: Date = Date(), expiresAt: Date) {
        self.id = id; self.sessionKey = sessionKey; self.agentID = agentID; self.tool = tool; self.summary = summary
        self.detail = detail; self.suggestions = suggestions; self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}

/// What the user chose for a pending approval. Mapped to the agent's decision JSON server-side, never echoed from client text.
public enum ApprovalDecision: Sendable, Equatable {
    case allowOnce
    case deny(message: String?)
    case letTerminalDecide                     // close without a decision: the agent shows its own prompt
    case allowAlways(suggestionIndex: Int)     // only offered behind an explicit confirmation
}

public struct AgentUsageSnapshot: Codable, Sendable, Equatable {
    public var costUSD: Double?
    public var contextUsedPercent: Double?
    public var fiveHourPercent: Double?
    public var sevenDayPercent: Double?
    public var source: String
    public init(costUSD: Double? = nil, contextUsedPercent: Double? = nil, fiveHourPercent: Double? = nil,
                sevenDayPercent: Double? = nil, source: String) {
        self.costUSD = costUSD; self.contextUsedPercent = contextUsedPercent
        self.fiveHourPercent = fiveHourPercent; self.sevenDayPercent = sevenDayPercent; self.source = source
    }
}

public struct AgentSession: Identifiable, Sendable, Equatable {
    public var key: SessionKey
    public var id: String { "\(key.kind.rawValue):\(key.id)" }
    public var name: String?
    public var title: String?                  // /rename, ai-title, thread name, else first prompt
    public var cwd: String
    public var projectName: String
    public var surface: Surface
    public var pid: Int32?
    public var processStart: Date?             // guards against PID reuse
    public var tty: String?
    public var hostAppBundleID: String?
    public var jump: JumpTarget?
    public var status: SessionStatus
    public var statusSince: Date
    public var waitingFor: String?
    public var permissionMode: String?
    public var model: String?
    public var currentTool: ToolActivity?
    public var lastPrompt: String?
    public var lastAssistantText: String?
    public var tasks: [AgentTask]
    public var subagents: [Subagent]
    public var usage: AgentUsageSnapshot?
    public var transcriptPath: String?
    public var lastEventAt: Date
    /// true when seen through a live hook channel (exact state). false = discovered passively (limited detail, no approvals).
    public var isLive: Bool
    public var provenance: Provenance
    /// ADDITIVE. true after a running -> idle/done transition (Stop, or a passive session going quiet/exiting) until the user
    /// looks (activates the host app, jumps, starts a new prompt, or the center is told to acknowledge). Never kept > 24 h.
    public var hasUnseenCompletion: Bool = false
    /// ADDITIVE. Short caveat about how `status` was obtained, e.g. "estimated from activity" for passive (no hook)
    /// sessions, whose "running" lingers ~30 s after the agent finishes. nil = exact (hook) or registry-reported.
    public var statusDetail: String?

    public init(key: SessionKey, cwd: String, projectName: String? = nil, status: SessionStatus = .unknown, now: Date = Date()) {
        self.key = key; self.cwd = cwd
        self.projectName = projectName ?? (cwd as NSString).lastPathComponent
        self.surface = .unknown; self.status = status; self.statusSince = now; self.lastEventAt = now
        self.tasks = []; self.subagents = []; self.isLive = false; self.provenance = .processScan
    }
}

// MARK: - The user's own board (sections and small tasks). Persisted locally; nothing leaves the Mac.

public struct BoardTask: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var isDone: Bool
    public var createdAt: Date
    public var linkedSessionID: String?        // AgentSession.id this task was started on
    public var agent: AgentKind?               // which agent it was last sent to
    public init(id: UUID = UUID(), title: String, notes: String = "", isDone: Bool = false, createdAt: Date = Date(),
                linkedSessionID: String? = nil, agent: AgentKind? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.isDone = isDone; self.createdAt = createdAt
        self.linkedSessionID = linkedSessionID; self.agent = agent
    }
}

public struct BoardSection: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var tasks: [BoardTask]
    public var isCollapsed: Bool
    public init(id: UUID = UUID(), title: String, tasks: [BoardTask] = [], isCollapsed: Bool = false) {
        self.id = id; self.title = title; self.tasks = tasks; self.isCollapsed = isCollapsed
    }
}
