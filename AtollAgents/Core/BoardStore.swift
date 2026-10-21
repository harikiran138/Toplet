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
import Darwin

/// Local persistence of the user's board (sections and small tasks):
/// `~/Library/Application Support/Atoll/agents-board.json`. Versioned, atomic, debounced, bounded, tolerant on load.
/// Nothing leaves the Mac.
final class BoardStore {
    static let currentVersion = 1
    static let maxSections = 200
    static let maxTasks = 2000
    static let maxTitle = 200
    static let maxNotes = 4000
    static let maxFileBytes = 8 << 20

    let url: URL
    let debounce: TimeInterval
    private let queue = DispatchQueue(label: "atoll.agents.board", qos: .utility)
    private var pending: [BoardSection]?
    private var work: DispatchWorkItem?
    private var writes = 0

    /// Called (on an arbitrary queue) when a save fails.
    var onError: ((String) -> Void)?
    private(set) var lastLoadWasCorrupt = false

    init(url: URL = BoardStore.defaultURL(), debounce: TimeInterval = 0.5) {
        self.url = url; self.debounce = debounce
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Atoll", isDirectory: true).appendingPathComponent("agents-board.json")
    }

    var writeCount: Int { queue.sync { writes } }

    // MARK: Coding

    private struct FileModel: Codable {
        var version: Int
        var sections: [BoardSection]
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let s = try? c.decode(String.self), let date = JSONField.date(s) { return date }
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n) }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date")
        }
        return d
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try c.encode(f.string(from: date))
        }
        return e
    }

    // MARK: Load

    /// Never throws or crashes. A corrupt file is copied to `<file>.corrupt` and an empty board is returned.
    func load() -> [BoardSection] {
        lastLoadWasCorrupt = false
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return [] }   // no file yet
        if let size = attrs[.size] as? NSNumber, size.intValue > BoardStore.maxFileBytes { return quarantine() }
        guard let data = try? Data(contentsOf: url) else { return quarantine() }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return quarantine() }
        let version = JSONField.int(obj, "version") ?? 0
        guard version >= 1, version <= BoardStore.currentVersion, let raw = obj["sections"] as? [Any] else { return quarantine() }

        let dec = BoardStore.makeDecoder()
        var sections: [BoardSection] = []
        var skipped = 0
        for item in raw.prefix(BoardStore.maxSections * 2) {
            guard JSONSerialization.isValidJSONObject(item), let d = try? JSONSerialization.data(withJSONObject: item),
                  let s = try? dec.decode(BoardSection.self, from: d) else { skipped += 1; continue }
            sections.append(s)
        }
        if skipped > 0 { lastLoadWasCorrupt = true; copyCorrupt() }
        return BoardStore.sanitize(sections)
    }

    private func quarantine() -> [BoardSection] {
        lastLoadWasCorrupt = true
        copyCorrupt()
        return []
    }

    private func copyCorrupt() {
        let dest = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    // MARK: Save (debounced, atomic)

    func scheduleSave(_ sections: [BoardSection]) {
        queue.async { [self] in
            pending = sections
            work?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.writePending() }
            work = w
            queue.asyncAfter(deadline: .now() + debounce, execute: w)
        }
    }

    /// Writes any pending board now (synchronously).
    func flush() {
        queue.sync {
            work?.cancel(); work = nil
            writePending()
        }
    }

    private func writePending() {
        guard let sections = pending else { return }
        pending = nil
        let model = FileModel(version: BoardStore.currentVersion, sections: BoardStore.sanitize(sections))
        do {
            let data = try BoardStore.makeEncoder().encode(model)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            chmod(url.path, 0o600)
            writes += 1
        } catch {
            onError?("Could not save the board: \(error.localizedDescription)")
        }
    }

    // MARK: Bounds

    static func cleanTitle(_ s: String) -> String { AgentText.clean(s, max: maxTitle) }
    static func cleanNotes(_ s: String) -> String { AgentText.clean(s, max: maxNotes, multiline: true) }

    /// Enforces the limits: <= 200 sections, <= 2000 tasks, titles <= 200 chars, notes <= 4000, unique ids.
    static func sanitize(_ sections: [BoardSection]) -> [BoardSection] {
        var out: [BoardSection] = []
        var taskCount = 0
        var seenSections = Set<UUID>(), seenTasks = Set<UUID>()
        for var s in sections.prefix(maxSections) {
            guard seenSections.insert(s.id).inserted else { continue }
            let t = cleanTitle(s.title)
            s.title = t.isEmpty ? "Untitled" : t
            var tasks: [BoardTask] = []
            for var task in s.tasks {
                guard taskCount < maxTasks, seenTasks.insert(task.id).inserted else { continue }
                let tt = cleanTitle(task.title)
                task.title = tt.isEmpty ? "Untitled task" : tt
                task.notes = cleanNotes(task.notes)
                if let l = task.linkedSessionID { task.linkedSessionID = AgentText.cleanOptional(l, max: 160) }
                tasks.append(task)
                taskCount += 1
            }
            s.tasks = tasks
            out.append(s)
        }
        return out
    }
}
