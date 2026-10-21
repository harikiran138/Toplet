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

// The `HookInstalling` protocol itself lives in Core/HookInstalling.swift (owned by the core agent) and `HooksState` in
// Core/AgentCenter.swift. Core's protocol is `install(claude:codex:) throws` / `uninstall() throws` returning Void;
// HookInstaller conforms to it and ALSO offers `installWithReport` / `uninstallWithReport` returning the structured
// `HookInstallReport` below (for UI messages: events added, backup path, Codex /hooks trust reminder, warnings).

/// What happened to ONE agent config file.
public struct HookFileChange: Equatable, Sendable {
    public var agent: AgentKind
    public var path: String
    /// The file did not exist before this operation.
    public var created = false
    /// Events for which an Atoll entry was added.
    public var added: [String] = []
    /// Events that already had Atoll's exact entry (idempotent re-install).
    public var alreadyPresent: [String] = []
    /// Events from which an Atoll entry was removed (uninstall).
    public var removed: [String] = []
    /// Events where an older / other-socket Atoll entry was removed (and, on install, replaced).
    public var staleRemoved: [String] = []
    public var backupPath: String?
    public var wroteFile = false
    public var warnings: [String] = []
    public var notes: [String] = []
    public var nothingToChange: Bool { added.isEmpty && removed.isEmpty && staleRemoved.isEmpty }
    public init(agent: AgentKind, path: String) { self.agent = agent; self.path = path }
}

public struct HookInstallReport: Equatable, Sendable {
    public var action: String                    // "install" | "uninstall"
    public var files: [HookFileChange]
    public var warnings: [String]
    /// true when Codex got new or changed hook definitions: the user must run /hooks in Codex once.
    public var needsCodexTrustReview: Bool
    public var summary: String
}

public enum AgentHookState: Equatable, Sendable {
    case notInstalled
    case installed
    case partial(present: Int, expected: Int)
    /// File exists but cannot be read or parsed (Atoll will not touch it).
    case unreadable(String)
}

public struct HooksDetailedState: Equatable, Sendable {
    public var claude: AgentHookState
    public var codex: AgentHookState
}

public enum HookInstallError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidSocketPath(String)
    /// The file exists but is not valid JSON (or not UTF-8, or too large). Atoll refuses to write and changes nothing.
    case unparseable(path: String, reason: String)
    /// Valid JSON, but not the shape Atoll can merge into safely (e.g. `hooks` is an array).
    case unexpectedShape(path: String, detail: String)
    case readOnly(path: String)
    case notWritable(path: String, reason: String)
    case modifiedConcurrently(path: String)
    case io(path: String, reason: String)
    /// An earlier file was written, a later one failed. `report` describes what DID happen.
    case partiallyApplied(report: HookInstallReport, failedPath: String, reason: String)

    public var description: String {
        switch self {
        case .invalidSocketPath(let r): return "Invalid socket path: \(r)"
        case .unparseable(let p, let r): return "Toplet did not touch \(p): it is not valid JSON (\(r)). Fix or remove the file, then try again."
        case .unexpectedShape(let p, let d): return "Toplet did not touch \(p): unexpected structure (\(d))."
        case .readOnly(let p): return "Toplet did not touch \(p): the file is read-only."
        case .notWritable(let p, let r): return "Toplet cannot write \(p): \(r)."
        case .modifiedConcurrently(let p): return "\(p) changed while Toplet was preparing the edit; nothing was written. Try again."
        case .io(let p, let r): return "I/O error for \(p): \(r)."
        case .partiallyApplied(_, let p, let r): return "Some changes were applied, but writing \(p) failed: \(r)."
        }
    }
    public var errorDescription: String? { description }
}
