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

/// Shared merge engine for "JSON file with a top-level `hooks` object": Claude Code `settings.json` and Codex `hooks.json`
/// have the same shape (verified, docs/AI-AGENTS-HOOK-FORMATS.md):
///   { ..., "hooks": { "<Event>": [ { "matcher"?: "...", "hooks": [ { "type": "command", "command": "...", "timeout": N } ] } ] } }
///
/// Guarantees:
/// - the file is parsed with a strict order-preserving reader; if it exists and cannot be parsed, NOTHING is written
///   (never "start from {}"); an empty / whitespace-only file is the only exception (nothing to lose)
/// - every key, value and key order the user has is preserved; only whitespace is normalised (see OrderedJSON)
/// - Atoll's entries are recognised by the EXACT command string (the handler schema forbids extra keys, so there is
///   no room for a marker field: additionalProperties=false on the command handler in the published schema)
/// - the user's own hooks, including ones on the same events, are never modified or removed
/// - idempotent: when everything is already current the file is not rewritten and no backup is made
final class HooksFileEditor {
    enum Mode { case install, uninstall }

    struct Plan {
        var change: HookFileChange
        var snapshot: HooksFileIO.Snapshot
        var originalText: String
        var newText: String?            // nil = nothing to write
    }

    let agent: AgentKind
    let path: String
    let entries: [HookCommand.Entry]
    let documentWarnings: (JSONValue) -> [String]
    let notes: [String]
    let now: () -> Date

    init(agent: AgentKind, path: String, entries: [HookCommand.Entry], notes: [String] = [],
         documentWarnings: @escaping (JSONValue) -> [String] = { _ in [] }, now: @escaping () -> Date = Date.init) {
        self.agent = agent; self.path = path; self.entries = entries; self.notes = notes
        self.documentWarnings = documentWarnings; self.now = now
    }

    private var exactCommands: Set<String> { Set(entries.map { $0.command }) }

    private enum Ownership { case exact, stale, none }
    private func classify(_ command: String) -> Ownership {
        if exactCommands.contains(command) { return .exact }
        return HookCommand.looksLikeAtoll(command, agent: agent) ? .stale : .none
    }

    // MARK: Loading

    private struct Loaded {
        var snapshot: HooksFileIO.Snapshot
        var root: [JSONMember]
        var style: JSONWriteStyle
        var text: String
    }

    private func load() throws -> Loaded {
        let snap = try HooksFileIO.read(path)
        guard let data = snap.data else { return Loaded(snapshot: snap, root: [], style: JSONWriteStyle(), text: "") }
        let text = String(decoding: data, as: UTF8.self)
        // whitespace-only (optionally BOM): nothing to lose
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        if body.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            var st = JSONWriteStyle()
            st.bom = data.count >= 3 && data.starts(with: [0xEF, 0xBB, 0xBF])
            return Loaded(snapshot: snap, root: [], style: st, text: text)
        }
        do {
            let (v, style) = try OrderedJSON.parse(data)
            guard case .object(let members) = v else {
                throw HookInstallError.unexpectedShape(path: path, detail: "top-level value is not a JSON object")
            }
            return Loaded(snapshot: snap, root: members, style: style, text: text)
        } catch let e as JSONParseError {
            throw HookInstallError.unparseable(path: path, reason: e.description)
        }
    }

    // MARK: Transform (pure)

    struct Transformed {
        var root: [JSONMember]
        var added: [String] = []
        var present: [String] = []
        var removed: [String] = []
        var stale: [String] = []
        var modified: Bool { !added.isEmpty || !removed.isEmpty || !stale.isEmpty }
    }

    private func shape(_ d: String) -> HookInstallError { .unexpectedShape(path: path, detail: d) }

    private func newGroup(_ e: HookCommand.Entry) -> JSONValue {
        .object([JSONMember("hooks", .array([.object([
            JSONMember("type", .str("command")),
            JSONMember("command", .str(e.command)),
            JSONMember("timeout", .number(String(e.timeout))),
        ])]))])
    }

    func transform(root rootIn: [JSONMember], mode: Mode) throws -> Transformed {
        var out = Transformed(root: rootIn)
        let hookIdx = rootIn.indices(ofKey: "hooks")
        if hookIdx.count > 1 { throw shape("the key \"hooks\" appears more than once") }
        var hooksMembers = [JSONMember]()
        if let hi = hookIdx.first {
            guard case .object(let m) = rootIn[hi].value else { throw shape("\"hooks\" is not an object") }
            hooksMembers = m
        }
        var seen = Set<String>()
        for m in hooksMembers where !seen.insert(m.key).inserted { throw shape("hook event \"\(m.key)\" appears more than once") }

        let ours = Dictionary(uniqueKeysWithValues: entries.map { ($0.event, $0) })
        var addedSet = Set<String>(), presentSet = Set<String>(), removedSet = Set<String>(), staleSet = Set<String>()
        var staleOrder = [String](), removedOrder = [String]()

        var i = 0
        while i < hooksMembers.count {
            let ev = hooksMembers[i].key
            guard case .array(let groups) = hooksMembers[i].value else {
                if ours[ev] != nil { throw shape("hooks.\(ev) is not an array") }
                i += 1; continue
            }
            var exactKept = 0
            var anyChange = false
            var eventStale = false, eventRemoved = false
            var newGroups = [JSONValue]()
            for group in groups {
                guard case .object(var gm) = group, let hIdx = gm.indices(ofKey: "hooks").first,
                      case .array(let handlers) = gm[hIdx].value else { newGroups.append(group); continue }
                var kept = [JSONValue]()
                var changed = false
                for h in handlers {
                    guard case .object(let hm) = h, hm.first(key: "type")?.stringValue == "command",
                          let cmd = hm.first(key: "command")?.stringValue else { kept.append(h); continue }
                    switch classify(cmd) {
                    case .exact:
                        if mode == .uninstall { changed = true; eventRemoved = true } else { exactKept += 1; kept.append(h) }
                    case .stale:
                        changed = true; eventStale = true
                    case .none:
                        kept.append(h)
                    }
                }
                if changed {
                    anyChange = true
                    if kept.isEmpty { continue }              // group held only Atoll's handlers: drop it
                    gm[hIdx].value = .array(kept)
                    newGroups.append(.object(gm))
                } else {
                    newGroups.append(group)
                }
            }
            if eventStale, staleSet.insert(ev).inserted { staleOrder.append(ev) }
            if eventRemoved, removedSet.insert(ev).inserted { removedOrder.append(ev) }
            if mode == .install, let e = ours[ev] {
                if exactKept == 0 { newGroups.append(newGroup(e)); addedSet.insert(ev); anyChange = true }
                else { presentSet.insert(ev) }
            }
            if anyChange {
                if newGroups.isEmpty { hooksMembers.remove(at: i); continue }   // only reachable when we removed something
                hooksMembers[i].value = .array(newGroups)
            }
            i += 1
        }

        if mode == .install {
            for e in entries where !hooksMembers.contains(where: { $0.key == e.event }) {
                hooksMembers.append(JSONMember(e.event, .array([newGroup(e)])))
                addedSet.insert(e.event)
            }
        }

        let order = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.event, $0) })
        func ordered(_ s: Set<String>, extra: [String]) -> [String] {
            let known = entries.map { $0.event }.filter { s.contains($0) }
            return known + extra.filter { order[$0] == nil }
        }
        out.added = ordered(addedSet, extra: [])
        out.present = ordered(presentSet, extra: [])
        out.removed = ordered(removedSet, extra: removedOrder)
        out.stale = ordered(staleSet, extra: staleOrder)

        if out.modified {
            if hooksMembers.isEmpty {
                if let hi = hookIdx.first { out.root.remove(at: hi) }
            } else if let hi = hookIdx.first {
                out.root[hi].value = .object(hooksMembers)
            } else {
                out.root.append(JSONMember("hooks", .object(hooksMembers)))
            }
        }
        return out
    }

    // MARK: Plan / commit / inspect

    func plan(_ mode: Mode) throws -> Plan {
        let loaded = try load()
        let t = try transform(root: loaded.root, mode: mode)
        var change = HookFileChange(agent: agent, path: path)
        change.created = !loaded.snapshot.exists
        change.added = t.added
        change.alreadyPresent = t.present
        change.removed = t.removed
        change.staleRemoved = t.stale
        change.warnings = documentWarnings(.object(loaded.root))
        change.notes = notes
        var newText: String?
        if t.modified {
            try HooksFileIO.checkWritable(loaded.snapshot)
            var style = loaded.style
            if !loaded.snapshot.exists || loaded.text.isEmpty { style.trailingNewline = true }
            newText = OrderedJSON.serialize(.object(t.root), style: style)
        }
        return Plan(change: change, snapshot: loaded.snapshot, originalText: loaded.text, newText: newText)
    }

    func commit(_ plan: Plan) throws -> HookFileChange {
        var change = plan.change
        guard let newText = plan.newText else { return change }
        // lost-update guard BEFORE any side effect (atomicWrite checks again right before the rename)
        if (try? Data(contentsOf: URL(fileURLWithPath: plan.snapshot.resolvedPath))) != plan.snapshot.data {
            throw HookInstallError.modifiedConcurrently(path: path)
        }
        if let orig = plan.snapshot.data {
            change.backupPath = try HooksFileIO.writeBackup(userPath: path, data: orig, now: now())
        }
        try HooksFileIO.atomicWrite(Data(newText.utf8), to: plan.snapshot)
        change.wroteFile = true
        HooksFileIO.rotateBackups(userPath: path)
        return change
    }

    /// Tolerant: never throws. Exact-command match per event.
    func inspect() -> AgentHookState {
        let loaded: Loaded
        do { loaded = try load() } catch { return .unreadable("\(error)") }   // a missing file loads as an empty document
        guard let hooks = loaded.root.first(key: "hooks")?.objectValue else { return .notInstalled }
        var present = 0
        for e in entries {
            guard let groups = hooks.first(key: e.event)?.arrayValue else { continue }
            let found = groups.contains { g in
                guard let hs = g.objectValue?.first(key: "hooks")?.arrayValue else { return false }
                return hs.contains { h in
                    guard let hm = h.objectValue, hm.first(key: "type")?.stringValue == "command" else { return false }
                    return hm.first(key: "command")?.stringValue == e.command
                }
            }
            if found { present += 1 }
        }
        if present == 0 { return .notInstalled }
        return present == entries.count ? .installed : .partial(present: present, expected: entries.count)
    }
}
