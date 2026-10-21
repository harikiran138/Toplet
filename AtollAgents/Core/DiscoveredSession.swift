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

/// One session found passively (registry file, process table, transcript/rollout tail). Merged by SessionReducer
/// with per-field provenance, so a live hook channel always wins over these.
struct DiscoveredSession: Equatable, Sendable {
    var key: SessionKey
    /// Strongest source of the identity/process facts (registry > rollout/transcript > processScan).
    var provenance: Provenance
    var cwd: String
    var name: String?
    var title: String?
    var pid: Int32?
    var processStart: Date?
    var tty: String?
    var hostAppBundleID: String?
    var surface: Surface?
    var jump: JumpTarget?
    var status: SessionStatus?
    var statusProvenance: Provenance
    var statusSince: Date?
    var waitingFor: String?
    var textProvenance: Provenance
    var lastPrompt: String?
    var lastAssistantText: String?
    var tasks: [AgentTask]?
    var model: String?
    var usage: UsageSnapshot?
    var transcriptPath: String?
    var lastActivity: Date?
    /// Diagnostic note, e.g. "rollout is compressed (.zst): details unavailable".
    var note: String?
    /// How `status` was obtained when it is not exact ("estimated from activity").
    var statusDetail: String?
    /// Codex: the parent thread of a subagent thread (`parent_thread_id` in session_meta). Grouped under the parent.
    var parentID: String?
    /// Claude: subagents found as `<session>/subagents/agent-*.jsonl`.
    var subagents: [Subagent]?
    /// Last write time of the transcript/rollout file (the passive busy/idle signal).
    var fileMTime: Date?

    init(key: SessionKey, provenance: Provenance, cwd: String = "") {
        self.key = key; self.provenance = provenance; self.cwd = cwd
        self.statusProvenance = provenance; self.textProvenance = provenance
    }
}

/// Tunables of the passive (no hook) mode. The 30 s busy window, subagent grouping via parent_thread_id and the
/// <session>/subagents/agent-*.jsonl layout are ideas credited to realfishsam/agent-notch (MIT); the code is our own. Passive "running" is an ESTIMATE: it means the transcript/rollout file was
/// written within `busyWindow`, so it lingers up to ~30 s ("afterglow") after the agent actually finished, and a long
/// silent tool run shows as idle. A live hook status always overrides it.
struct PassivePolicy: Equatable, Sendable {
    /// Process alive and file written this recently => running; otherwise idle.
    var busyWindow: TimeInterval = 30
    /// A passive session missing from this many consecutive complete scans is done.
    var missesToEnd = 2
    /// Idle (non-live) sessions older than this are dropped.
    var idleDrop: TimeInterval = 6 * 3600
    /// Completion flags are never kept longer than this.
    var unseenMax: TimeInterval = 24 * 3600
    static let `default` = PassivePolicy()
    static let estimatedDetail = "estimated from activity"
}
