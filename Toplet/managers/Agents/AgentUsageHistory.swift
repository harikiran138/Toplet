import Foundation
import CoreFoundation

/// Local, incremental accounting. Context-window snapshots are deliberately NOT summed.
/// Checkpoints and deduplicated request records are committed together so restarts do not double count.
struct AgentTokenTotals: Codable, Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var total: Int { input + output + cacheRead + cacheWrite }
    mutating func add(_ v: Self) {
        input += v.input; output += v.output; cacheRead += v.cacheRead; cacheWrite += v.cacheWrite
    }
}

struct AgentUsageRecord: Codable, Equatable, Sendable {
    var id: String
    var kind: AgentKind
    var sessionID: String
    var project: String
    var model: String
    var at: Date
    var tokens: AgentTokenTotals
}

struct AgentUsageReport: Equatable, Sendable {
    var records: [AgentUsageRecord] = []
    var updatedAt: Date?
    var indexing = false
    var issue: String?
    func totals(since start: Date, until end: Date, kind: AgentKind? = nil) -> AgentTokenTotals {
        var total = AgentTokenTotals()
        for r in records where r.at >= start && r.at <= end && (kind == nil || r.kind == kind) { total.add(r.tokens) }
        return total
    }
    func totals(for key: SessionKey) -> AgentTokenTotals {
        var total = AgentTokenTotals()
        for r in records where r.kind == key.kind && r.sessionID == key.id { total.add(r.tokens) }
        return total
    }
}

actor AgentUsageHistory {
    struct Cursor: Codable, Equatable {
        var offset: UInt64 = 0
        var inode: UInt64 = 0
        var model = "unknown"
        var sessionID = ""
        var project = ""
        var cumulative: AgentTokenTotals?
        var discarding = false
    }
    struct Archive: Codable, Equatable {
        var version = 1
        var cursors: [String: Cursor] = [:]
        var records: [String: AgentUsageRecord] = [:]
    }
    private let roots: [(AgentKind, URL)]
    private let archiveURL: URL?
    private var archive = Archive()
    private var loaded = false
    /// The checkpoint is rewritten at most this often (it can be several MB). Losing the last
    /// interval on a crash is safe: records are keyed by request id, so re-reading never double counts.
    private let saveInterval: TimeInterval
    private var lastSaved: Date?
    /// Set whenever cursors or records change; replaces copying and comparing the whole archive.
    private var dirty = false
    /// Sorted records for the report, rebuilt only when the records change.
    private var sortedRecords: [AgentUsageRecord] = []
    private var recordsChanged = true
    private var lastChange: Date?
    static let readBudget = 8 * 1024 * 1024
    static let lineLimit = 1024 * 1024
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    init(claudeRoot: URL, codexRoot: URL, archiveURL: URL?, saveInterval: TimeInterval = 60) {
        roots = [(.claudeCode, claudeRoot), (.codex, codexRoot)]
        self.archiveURL = archiveURL
        self.saveInterval = saveInterval
    }

    /// Writes pending changes now (call when the feature stops or the app quits).
    func flush() {
        guard dirty else { return }
        _ = save(now: Date())
    }
    func refresh(now: Date = Date()) -> AgentUsageReport {
        autoreleasepool { refreshImpl(now: now) }
    }
    private func refreshImpl(now: Date) -> AgentUsageReport {
        if !loaded {
            loaded = true
            if let url = archiveURL, let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
               (attrs.fileSize ?? 0) <= 32 * 1024 * 1024,
               let data = try? Data(contentsOf: url), let old = try? JSONDecoder().decode(Archive.self, from: data), old.version == 1 {
                archive = old
            }
        }
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let expired = archive.records.filter { $0.value.at < cutoff || $0.value.at > now }.map(\.key)
        if !expired.isEmpty {
            for key in expired { archive.records.removeValue(forKey: key) }
            markRecordsChanged(now)
        }
        var budget = Self.readBudget
        var indexing = false
        var seenPaths = Set<String>()
        var files: [(AgentKind, URL, Date)] = []
        for (kind, root) in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in walker {
                guard file.pathExtension == "jsonl", let v = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      v.isRegularFile == true, let date = v.contentModificationDate, date >= cutoff else { continue }
                files.append((kind, file, date))
            }
        }
        // Recently active files first. Cursors ensure large files eventually complete without blocking the UI.
        files.sort { $0.2 > $1.2 }
        for (kind, file, _) in files {
            seenPaths.insert(file.path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = attrs[.size] as? NSNumber, let inode = attrs[.systemFileNumber] as? NSNumber else { continue }
            var c = archive.cursors[file.path] ?? Cursor()
            if c.inode != inode.uint64Value || c.offset > size.uint64Value { c = Cursor(); c.inode = inode.uint64Value }
            if c.sessionID.isEmpty { c.sessionID = file.deletingPathExtension().lastPathComponent }
            if c.project.isEmpty { c.project = file.deletingLastPathComponent().lastPathComponent }
            guard c.offset < size.uint64Value else { continue }
            guard budget > 0, let handle = try? FileHandle(forReadingFrom: file) else { indexing = true; continue }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: c.offset)
                let data = try handle.read(upToCount: min(budget, 2 * 1024 * 1024)) ?? Data()
                budget -= data.count
                var start = data.startIndex
                for i in data.indices where data[i] == 10 {
                    let line = data.subdata(in: start..<i)
                    if !c.discarding && line.count <= Self.lineLimit {
                        autoreleasepool {
                            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                                consume(obj, kind: kind, cursor: &c, offset: c.offset + UInt64(start), cutoff: cutoff, now: now)
                            }
                        }
                    }
                    c.discarding = false
                    start = i + 1
                }
                c.offset += UInt64(start)
                // Retain an incomplete line for the next pass. Oversized records are skipped in bounded chunks.
                if data.count - start > Self.lineLimit { c.offset += UInt64(data.count - start); c.discarding = true }
                if c.offset < size.uint64Value { indexing = true }
                if archive.cursors[file.path] != c { archive.cursors[file.path] = c; dirty = true }
            } catch { indexing = true }
        }
        let gone = archive.cursors.keys.filter { !seenPaths.contains($0) }
        if !gone.isEmpty {
            for key in gone { archive.cursors.removeValue(forKey: key) }
            dirty = true
        }
        // Keep a bounded archive. Report the limitation instead of claiming full coverage.
        var issue: String?
        if archive.records.count > 100_000 {
            let newest = archive.records.values.sorted { $0.at > $1.at }.prefix(100_000)
            archive.records = Dictionary(uniqueKeysWithValues: newest.map { ($0.id, $0) })
            markRecordsChanged(now)
            issue = "History reached its 100,000-request limit; older totals may be incomplete."
        }
        if let url = archiveURL {
            let due = lastSaved.map { now.timeIntervalSince($0) >= saveInterval || now < $0 } ?? true
            if (dirty && due) || !FileManager.default.fileExists(atPath: url.path) {
                if !save(now: now) { issue = "Usage is available, but its local checkpoint could not be saved." }
            }
        }
        if recordsChanged {
            sortedRecords = archive.records.values.sorted { $0.at < $1.at }
            recordsChanged = false
        }
        // An unchanged refresh returns an identical report, so observers are not woken every pass.
        return AgentUsageReport(records: sortedRecords, updatedAt: lastChange ?? now, indexing: indexing, issue: issue)
    }

    private func markRecordsChanged(_ now: Date) {
        dirty = true
        recordsChanged = true
        lastChange = now
    }

    @discardableResult
    private func save(now: Date) -> Bool {
        guard let url = archiveURL else { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(archive)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            dirty = false
            lastSaved = now
            return true
        } catch {
            return false
        }
    }
    private func number(_ d: [String: Any], _ key: String) -> Int {
        guard let n = d[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return 0 }
        let v = n.doubleValue
        return v.isFinite && v >= 0 && v <= 1_000_000_000 ? Int(v) : 0
    }
    private func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return fractionalISO.date(from: s) ?? iso.date(from: s)
    }
    private func consume(_ obj: [String: Any], kind: AgentKind, cursor c: inout Cursor, offset: UInt64, cutoff: Date, now: Date) {
        let p = obj["payload"] as? [String: Any] ?? [:]
        let type = obj["type"] as? String
        if kind == .codex {
            if type == "session_meta" { c.sessionID = p["id"] as? String ?? c.sessionID; c.project = (p["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? c.project }
            if type == "turn_context" { c.model = p["model"] as? String ?? c.model }
        } else {
            c.sessionID = obj["sessionId"] as? String ?? c.sessionID
            c.project = (obj["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? c.project
        }
        c.sessionID = AgentText.clean(c.sessionID, max: 128)
        c.project = AgentText.clean(c.project, max: 80)
        c.model = AgentText.clean(c.model, max: 80)
        guard let at = date(obj["timestamp"]), at <= now else { return }
        var tokens = AgentTokenTotals()
        var requestID: String
        if kind == .claudeCode {
            guard type == "assistant", let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { return }
            tokens = AgentTokenTotals(input: number(u, "input_tokens"), output: number(u, "output_tokens"), cacheRead: number(u, "cache_read_input_tokens"), cacheWrite: number(u, "cache_creation_input_tokens"))
            c.model = AgentText.cleanOptional(msg["model"] as? String, max: 80) ?? c.model
            // Streamed updates can repeat the same response; replace component maxima, never sum frames.
            requestID = msg["id"] as? String ?? obj["uuid"] as? String ?? "offset:\(offset)"
        } else {
            guard type == "event_msg", p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
                  let u = info["total_token_usage"] as? [String: Any] else { return }
            let cached = number(u, "cached_input_tokens")
            let total = AgentTokenTotals(input: max(0, number(u, "input_tokens") - cached), output: number(u, "output_tokens"), cacheRead: cached)
            let previous = c.cumulative ?? AgentTokenTotals()
            // Counter resets start a new epoch; repeated cumulative snapshots contribute zero.
            let reset = total.input < previous.input || total.output < previous.output || total.cacheRead < previous.cacheRead
            tokens = reset ? total : AgentTokenTotals(input: total.input - previous.input, output: total.output - previous.output, cacheRead: total.cacheRead - previous.cacheRead)
            c.cumulative = total
            requestID = "\(obj["timestamp"] as? String ?? "")|\(total.input)|\(total.output)|\(total.cacheRead)"
        }
        guard at >= cutoff, tokens.total > 0 else { return }
        let id = "\(kind.rawValue)|\(c.sessionID)|\(AgentText.clean(requestID, max: 160))"
        if kind == .codex, archive.records[id] != nil { return }
        if let old = archive.records[id] {
            tokens = AgentTokenTotals(input: max(old.tokens.input, tokens.input), output: max(old.tokens.output, tokens.output), cacheRead: max(old.tokens.cacheRead, tokens.cacheRead), cacheWrite: max(old.tokens.cacheWrite, tokens.cacheWrite))
        }
        let record = AgentUsageRecord(id: id, kind: kind, sessionID: c.sessionID, project: AgentText.clean(c.project, max: 80), model: AgentText.clean(c.model, max: 80), at: at, tokens: tokens)
        if archive.records[id] != record {
            archive.records[id] = record
            markRecordsChanged(now)
        }
    }
}
