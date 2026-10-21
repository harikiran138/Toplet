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

// Tail-only reading of Claude transcripts (~/.claude/projects/<slug>/<id>.jsonl) and Codex rollouts
// (~/.codex/sessions/Y/M/D/rollout-*.jsonl). Transcripts exceed 100 MB: only the last 512 KB are ever read, and
// results are cached by (mtime, size). Compressed rollouts (.zst) are detected and skipped with a note.

struct TranscriptSummary: Equatable {
    var kind: AgentKind
    var sessionID: String
    var title: String?
    var lastPrompt: String?
    var lastAssistantText: String?
    var status: SessionStatus?
    var waitingFor: String?
    var tasks: [AgentTask]?
    var model: String?
    var cwd: String?
    var usage: AgentUsageSnapshot?
    var currentTool: ToolActivity?
    var lastEventAt: Date?
    var compressed = false
    var bytesRead = 0
    var headTruncated = false
    var note: String?
    /// Last write time of the file (the passive busy/idle signal).
    var fileMTime: Date?
    /// The last status-bearing event was a definitive end of turn (Claude end_turn, Codex task_complete/turn_aborted).
    var turnEnded = false
}

/// First-line metadata of a Codex rollout (cached forever: the first line never changes).
struct RolloutMeta: Equatable {
    var id: String?
    var cwd: String?
    var startedAt: Date?
    /// Set for subagent threads (`parent_thread_id` in session_meta).
    var parentThreadID: String?
}

final class TranscriptTail {
    static let tailBytes = 512 * 1024
    static let maxLineBytes = 256 * 1024
    static let headBytes = 64 * 1024

    private struct Cached { var mtime: Date; var size: Int64; var summary: TranscriptSummary }
    private var cache: [String: Cached] = [:]
    private var metaCache: [String: RolloutMeta?] = [:]
    private let lock = NSLock()

    /// Number of times a file was actually read (not served from cache). For tests.
    private(set) var readCount = 0

    init() {}

    func clearCache() { lock.lock(); cache.removeAll(); metaCache.removeAll(); lock.unlock() }

    // MARK: Summaries

    func summarize(path: String, kind: AgentKind, sessionID: String, includeSidechain: Bool = false) -> TranscriptSummary? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        let size = Int64(st.st_size)

        lock.lock()
        if let c = cache[path], c.mtime == mtime, c.size == size { lock.unlock(); return c.summary }
        lock.unlock()

        if path.hasSuffix(".zst") || path.hasSuffix(".zstd") {
            var s = TranscriptSummary(kind: kind, sessionID: sessionID)
            s.compressed = true
            s.lastEventAt = mtime
            s.fileMTime = mtime
            s.note = "Compressed rollout (.zst): details unavailable"
            store(path, mtime, size, s)
            return s
        }

        guard let tail = TranscriptTail.readTail(path: path, maxBytes: TranscriptTail.tailBytes) else { return nil }
        lock.lock(); readCount += 1; lock.unlock()

        var scratch = ReducerState()
        let key = SessionKey(kind: kind, id: sessionID)
        var cwd: String?
        var turnEnded = false
        for lineData in TranscriptTail.lines(of: tail.data, droppingFirst: tail.startedMidFile) {
            guard lineData.count <= TranscriptTail.maxLineBytes, let obj = JSONField.parseObject(lineData) else { continue }
            let events: [AgentEvent]
            switch kind {
            case .claudeCode: events = ClaudeEvents.decodeTranscriptLine(obj, sessionID: sessionID, includeSidechain: includeSidechain)
            case .codex: events = CodexEvents.decodeRolloutLine(obj, sessionID: sessionID)
            }
            for ev in events {
                if let c = ev.cwd, !c.isEmpty { cwd = c }
                switch ev.payload {
                case .stop, .turnCompleted, .turnAborted: turnEnded = true
                case .promptSubmit, .turnStarted, .toolStart: turnEnded = false
                default: break
                }
                SessionReducer.apply(ev, to: &scratch, now: mtime)
            }
        }
        var summary = TranscriptSummary(kind: kind, sessionID: sessionID)
        summary.bytesRead = tail.data.count
        summary.headTruncated = tail.startedMidFile
        summary.cwd = cwd
        summary.fileMTime = mtime
        summary.turnEnded = turnEnded
        if let s = scratch.sessions[key] {
            summary.title = s.title
            summary.lastPrompt = s.lastPrompt
            summary.lastAssistantText = s.lastAssistantText
            summary.tasks = s.tasks.isEmpty ? nil : s.tasks
            summary.model = s.model
            summary.usage = s.usage
            summary.currentTool = s.currentTool
            summary.lastEventAt = s.lastEventAt
            // A freshly created scratch session defaults to idle; only trust the status when something was actually replayed.
            if s.lastPrompt != nil || s.lastAssistantText != nil || s.currentTool != nil || s.status != .idle || !s.tasks.isEmpty {
                summary.status = s.status
                summary.waitingFor = s.waitingFor
            }
        }
        if summary.lastEventAt == nil { summary.lastEventAt = mtime }
        store(path, mtime, size, summary)
        return summary
    }

    private func store(_ path: String, _ mtime: Date, _ size: Int64, _ s: TranscriptSummary) {
        lock.lock()
        if cache.count > 256 { cache.removeAll() }
        cache[path] = Cached(mtime: mtime, size: size, summary: s)
        lock.unlock()
    }

    // MARK: Rollout head

    /// session_meta of a rollout (first line only). Cached per path.
    func rolloutMeta(path: String) -> RolloutMeta? {
        lock.lock()
        if let c = metaCache[path] { lock.unlock(); return c }
        lock.unlock()
        var result: RolloutMeta?
        if !path.hasSuffix(".zst"), let head = TranscriptTail.readHead(path: path, maxBytes: TranscriptTail.headBytes) {
            let first = head.prefix(while: { $0 != 0x0A })
            if let obj = JSONField.parseObject(Data(first)), (obj["type"] as? String) == "session_meta" {
                let p = (obj["payload"] as? [String: Any]) ?? [:]
                result = RolloutMeta(id: JSONField.nonEmptyString(p, "id"),
                                     cwd: AgentText.cleanOptional(JSONField.string(p, "cwd"), max: 512),
                                     startedAt: JSONField.date(JSONField.string(p, "timestamp") ?? obj["timestamp"] as? String),
                                     parentThreadID: Self.parentThread(p))
            }
        }
        lock.lock(); metaCache[path] = result; lock.unlock()
        return result
    }

    /// `parent_thread_id` of a subagent thread. The exact nesting is not documented, so look in a few plausible places.
    static func parentThread(_ p: [String: Any], depth: Int = 0) -> String? {
        if let id = JSONField.nonEmptyString(p, "parent_thread_id", "parentThreadId") { return AgentText.cleanOptional(id, max: 128) }
        guard depth < 4 else { return nil }
        for key in p.keys.sorted() { if let d = p[key] as? [String: Any], let id = parentThread(d, depth: depth + 1) { return id } }
        return nil
    }

    // MARK: Raw reads

    /// Reads at most `maxBytes` from the end of the file with pread (never the whole file).
    static func readTail(path: String, maxBytes: Int) -> (data: Data, size: Int64, startedMidFile: Bool)? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int64(st.st_size)
        let want = Int(min(Int64(maxBytes), size))
        if want <= 0 { return (Data(), size, false) }
        let offset = size - Int64(want)
        var buf = [UInt8](repeating: 0, count: want)
        var got = 0
        while got < want {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, want - got, off_t(offset) + off_t(got)) }
            if n <= 0 { break }
            got += n
        }
        return (Data(buf[0..<got]), size, offset > 0)
    }

    static func readHead(path: String, maxBytes: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: maxBytes)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, maxBytes, 0) }
        guard n > 0 else { return nil }
        return Data(buf[0..<n])
    }

    /// Splits on "\n". When the buffer starts mid-file the first (partial) line is dropped.
    static func lines(of data: Data, droppingFirst: Bool) -> [Data] {
        var out: [Data] = []
        var start = data.startIndex
        var first = true
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == 0x0A {
                if !(first && droppingFirst), i > start { out.append(data.subdata(in: start..<i)) }
                first = false
                start = data.index(after: i)
            }
            i = data.index(after: i)
        }
        if start < data.endIndex, !(first && droppingFirst) { out.append(data.subdata(in: start..<data.endIndex)) }
        return out
    }
}
