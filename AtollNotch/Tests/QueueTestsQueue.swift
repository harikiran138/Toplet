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

// T3: pure queue behaviour. Fake clock everywhere (the queue takes `now`), nothing touches the disk or the network.

let t0 = Date(timeIntervalSince1970: 1_000_000)

func mkQ(focus: Bool = false, _ f: (inout NotificationSettings) -> Void = { _ in }) -> NotificationQueue {
    NotificationQueue(settings: enabledSettings(f), isFocusActive: { focus }, fileExists: { _ in true })
}

private func shownID(_ d: NotificationQueue.Decision) -> UUID? { if case .shown(let id, _) = d { return id }; return nil }
private func preemptedID(_ d: NotificationQueue.Decision) -> UUID? { if case .shown(_, let p) = d { return p }; return nil }
private func queuedPos(_ d: NotificationQueue.Decision) -> Int? { if case .queued(_, let p) = d { return p }; return nil }
private func dedupedID(_ d: NotificationQueue.Decision) -> UUID? { if case .deduped(let id) = d { return id }; return nil }
private func silencedID(_ d: NotificationQueue.Decision) -> UUID? { if case .silenced(let id) = d { return id }; return nil }
private func pendingTitles(_ q: NotificationQueue) -> [String] { q.pending.map { $0.display.title } }
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

private func detID(_ i: Int) -> UUID { UUID(uuid: (UInt8(i >> 8 & 255), UInt8(i & 255), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)) }

/// Every string field of a display, joined. Used for leak assertions.
func allText(_ d: NotificationDisplay) -> String {
    [d.appName, d.iconSymbol ?? "", d.bundleID ?? "", d.title, d.subtitle ?? "", d.body ?? ""].joined(separator: "\u{1}")
}

/// True when any 4-gram of `hidden` appears in `output`.
func leaksNGram(_ hidden: String, in output: String, n: Int = 4) -> Bool {
    let h = Array(hidden)
    guard h.count >= n else { return output.contains(hidden) && !hidden.isEmpty }
    for i in 0...(h.count - n) where output.contains(String(h[i..<(i + n)])) { return true }
    return false
}

func runQueueTests() {
    section("Queue: accept, show, queue, order")
    do {
        var q = mkQ()
        let n1 = note("A"), n2 = note("B"), n3 = note("C")
        let d1 = q.accept(n1, now: at(0))
        eq(shownID(d1) ?? UUID(), n1.id, "first notification is shown")
        eq(q.current?.display.title ?? "", "A", "current is the first notification")
        eq(queuedPos(q.accept(n2, now: at(0))) ?? -1, 0, "second is queued at position 0")
        eq(queuedPos(q.accept(n3, now: at(0))) ?? -1, 1, "third is queued at position 1")
        eq(q.queuedCount, 2, "queuedCount")
        eq(q.nextDeadline ?? .distantPast, at(4), "deadline is now + default duration")
        q.advance(now: at(3.9))
        eq(q.current?.display.title ?? "", "A", "not expired before the deadline")
        q.advance(now: at(4))
        eq(q.current?.display.title ?? "", "B", "expires at the deadline and promotes the next")
        eq(q.nextDeadline ?? .distantPast, at(8), "promoted item gets a fresh deadline")
        q.advance(now: at(8)); q.advance(now: at(12))
        check(q.isIdle, "queue is idle after everything expired")
        eq(q.history.map { $0.display.title }, ["C", "B", "A"], "history is newest first")
        check(q.history.allSatisfy { $0.outcome == .expired && $0.wasShown }, "all three were shown and expired")
    }
    do {
        var q = mkQ { $0.enabled = false }
        eq(q.accept(note(), now: at(0)), .dropped(.disabled), "master switch off: dropped(disabled)")
        var q2 = mkQ { $0.enabledSources = [.atoll] }
        eq(q2.accept(note(source: .cli), now: at(0)), .dropped(.sourceDisabled), "source switched off: dropped(sourceDisabled)")
        check(shownID(q2.accept(note(source: .atoll), now: at(0))) != nil, "an enabled source still works")
        eq(q2.accept(note("   ", source: .atoll), now: at(0)), .dropped(.invalidContent), "whitespace-only title is invalid")
        eq(q2.accept(note("\u{202E}\u{200B}", source: .atoll), now: at(0)), .dropped(.invalidContent), "title of only bidi/zero-width characters is invalid")
        check(q2.history.isEmpty, "dropped notifications are not recorded")
    }
    do {  // priority ordering, deterministic
        var q = mkQ { $0.maxQueue = 20 }
        _ = q.accept(note("cur", priority: .critical, ttl: 300), now: at(0))
        for (t, p) in [("L1", NotificationPriority.low), ("N1", .normal), ("N2", .normal), ("L2", .low), ("H1", .high), ("N3", .normal)] {
            _ = q.accept(note(t, priority: p), now: at(0))
        }
        eq(pendingTitles(q), ["H1", "N1", "N2", "N3", "L1", "L2"], "pending order is priority desc, then arrival asc")
        var q2 = mkQ()
        var q3 = mkQ()
        for (t, p) in [("a", NotificationPriority.normal), ("b", .low), ("c", .high), ("d", .normal)] {
            _ = q2.accept(note(t, priority: p), now: at(0)); _ = q3.accept(note(t, priority: p), now: at(0))
        }
        eq(q2.pending.map { $0.display.title }, q3.pending.map { $0.display.title }, "same inputs give the same order")
    }
    section("Queue: preemption")
    do {
        var q = mkQ()
        let cur = note("cur")
        _ = q.accept(cur, now: at(0))
        let h = note("H", priority: .high)
        let d = q.accept(h, now: at(1.5))
        eq(shownID(d) ?? UUID(), h.id, "high preempts normal")
        eq(preemptedID(d) ?? UUID(), cur.id, "the decision names the preempted item")
        eq(pendingTitles(q), ["cur"], "the preempted item goes back to the queue")
        eq(q.pending.first?.remaining ?? 0, 2.5, "...with its remaining TTL (4 - 1.5)")
        q.advance(now: at(5.5))
        eq(q.current?.display.title ?? "", "cur", "when the high item ends the preempted one resumes")
        eq(q.nextDeadline ?? .distantPast, at(8), "...for exactly the remaining 2.5 s")
        eq(q.history.first?.outcome ?? .dismissed, .expired, "the high item expired normally")
    }
    do {
        var q = mkQ()
        _ = q.accept(note("low", priority: .low), now: at(0))
        check(queuedPos(q.accept(note("n", priority: .normal), now: at(0))) != nil, "normal does not preempt low (below the threshold)")
        var q2 = mkQ()
        _ = q2.accept(note("h", priority: .high), now: at(0))
        check(queuedPos(q2.accept(note("h2", priority: .high), now: at(0))) != nil, "high does not preempt high")
        var q3 = mkQ()
        _ = q3.accept(note("c", priority: .critical), now: at(0))
        check(queuedPos(q3.accept(note("h", priority: .high), now: at(0))) != nil, "high does not preempt critical")
        var q4 = mkQ()
        _ = q4.accept(note("h", priority: .high), now: at(0))
        check(shownID(q4.accept(note("c", priority: .critical), now: at(1))) != nil, "critical preempts high")
        var q5 = mkQ()
        _ = q5.accept(note("n"), now: at(0))
        check(shownID(q5.accept(note("c", priority: .critical), now: at(0))) != nil, "critical preempts normal")
        var q6 = mkQ()
        _ = q6.accept(note("n"), now: at(0))
        q6.preemptThreshold = .critical
        check(queuedPos(q6.accept(note("h", priority: .high), now: at(0))) != nil, "preempt threshold is tunable")
        var q7 = mkQ()
        _ = q7.accept(note("n"), now: at(0))
        let d = q7.accept(note("h", priority: .high), now: at(3.9995))
        check(shownID(d) != nil && q7.pending.isEmpty && q7.history.first?.outcome == .expired, "a preempted item with ~no time left expires instead of resuming")
    }
    section("Queue: TTL, stale, pause")
    do {
        var q = mkQ { $0.defaultDuration = 10 }
        _ = q.accept(note("a"), now: at(0))
        eq(q.nextDeadline ?? .distantPast, at(10), "ttl nil uses settings.defaultDuration")
        var q2 = mkQ()
        _ = q2.accept(note("a", ttl: 7), now: at(0))
        eq(q2.nextDeadline ?? .distantPast, at(7), "explicit ttl")
        var q3 = mkQ()
        _ = q3.accept(note("a", ttl: 0.1), now: at(0))
        eq(q3.nextDeadline ?? .distantPast, at(1), "tiny ttl is clamped up to 1 s")
        var q4 = mkQ()
        _ = q4.accept(note("a", ttl: 9999), now: at(0))
        eq(q4.nextDeadline ?? .distantPast, at(300), "huge ttl is clamped to 300 s")
        for (name, v) in [("NaN", Double.nan), ("infinity", .infinity), ("negative", -5), ("zero", 0)] {
            var qq = mkQ()
            _ = qq.accept(note("a", ttl: v), now: at(0))
            eq(qq.nextDeadline ?? .distantPast, at(4), "ttl \(name) falls back to the default")
        }
    }
    do {
        var q = mkQ()
        _ = q.accept(note("blocker", ttl: 300), now: at(0))
        _ = q.accept(note("waiting"), now: at(0))
        q.advance(now: at(121))
        check(q.pending.isEmpty, "a never-shown item older than pendingMaxAge is dropped on dequeue")
        eq(q.history.first?.outcome ?? .dismissed, .stale, "...and recorded as stale")
        check(q.history.first?.wasShown == false, "...and was never shown")
        var q2 = mkQ()
        _ = q2.accept(note("blocker", priority: .critical, ttl: 300), now: at(0))
        _ = q2.accept(note("crit", priority: .critical), now: at(0))
        q2.advance(now: at(250))
        eq(pendingTitles(q2), ["crit"], "critical items never go stale")
    }
    do {
        var q = mkQ()
        _ = q.accept(note("a"), now: at(0))
        _ = q.accept(note("b"), now: at(0))
        q.setPaused(true, now: at(1))
        check(q.nextDeadline == nil, "pause clears the deadline")
        eq(q.current?.remaining ?? 0, 3, "pause freezes the remaining time")
        q.advance(now: at(100))
        eq(q.current?.display.title ?? "", "a", "a paused item never expires")
        q.setPaused(false, now: at(100))
        eq(q.nextDeadline ?? .distantPast, at(103), "resume restores the remaining time")
        q.advance(now: at(103))
        eq(q.current?.display.title ?? "", "b", "expires after the remaining time once resumed")
        q.setPaused(true, now: at(104))
        _ = q.dismiss(id: q.current!.id, now: at(104))
        _ = q.accept(note("c"), now: at(105))
        check(q.current?.display.title == "c" && q.nextDeadline == nil, "an item promoted while paused starts paused")
        q.setPaused(false, now: at(110))
        eq(q.nextDeadline ?? .distantPast, at(114), "...and gets its full TTL on resume")
        q.setPaused(false, now: at(111))
        eq(q.nextDeadline ?? .distantPast, at(114), "resume twice is a no-op")
    }
    section("Queue: dedupe")
    do {
        var q = mkQ()
        let a = note("v1", key: "k")
        _ = q.accept(a, now: at(0))
        let d = q.accept(note("v2", key: "k"), now: at(2))
        eq(dedupedID(d) ?? UUID(), a.id, "same key replaces the current item (decision carries the existing id)")
        eq(q.current?.display.title ?? "", "v2", "content is replaced")
        eq(q.current?.id ?? UUID(), a.id, "id is kept")
        eq(q.nextDeadline ?? .distantPast, at(6), "replacing restarts the TTL")
        eq(q.queuedCount, 0, "nothing was queued")
    }
    do {
        var q = mkQ()
        _ = q.accept(note("cur", priority: .critical, ttl: 300), now: at(0))
        _ = q.accept(note("A1", key: "a"), now: at(0))
        _ = q.accept(note("B1", key: "b"), now: at(0))
        _ = q.accept(note("A2", key: "a"), now: at(1))
        eq(pendingTitles(q), ["A2", "B1"], "replacing a queued item keeps its position")
        _ = q.accept(note("B2", priority: .high, key: "b"), now: at(1))
        eq(pendingTitles(q), ["B2", "A2"], "a priority change on replace re-sorts")
    }
    do {
        var q = mkQ()
        let a = note("one", key: "k")
        _ = q.accept(a, now: at(0))
        _ = q.dismiss(id: a.id, now: at(1))
        eq(dedupedID(q.accept(note("one", key: "k"), now: at(5))) ?? UUID(), a.id, "identical content inside the window after dismissal is ignored")
        check(q.current == nil, "...and not shown again")
        check(shownID(q.accept(note("changed", key: "k"), now: at(6))) != nil, "changed content inside the window is a new notification")
        var q2 = mkQ()
        let b = note("x", key: "k")
        _ = q2.accept(b, now: at(0)); _ = q2.dismiss(id: b.id, now: at(1))
        check(dedupedID(q2.accept(note("x", key: "k"), now: at(9.9))) != nil, "9.9 s later: still inside the 10 s window")
        _ = q2.accept(note("x", key: "k"), now: at(15))
        var q3 = mkQ()
        let c = note("x", key: "k")
        _ = q3.accept(c, now: at(0)); _ = q3.dismiss(id: c.id, now: at(1))
        check(shownID(q3.accept(note("x", key: "k"), now: at(10))) != nil, "exactly at the window edge it is new again")
        var q4 = mkQ()
        let d = note("x", key: "k")
        _ = q4.accept(d, now: at(0)); _ = q4.dismiss(id: d.id, now: at(1))
        _ = q4.accept(note("x", key: "k"), now: at(8))
        check(dedupedID(q4.accept(note("x", key: "k"), now: at(16))) != nil, "a duplicate bumps the window (spam stays deduped)")
    }
    do {  // implicit key
        var q = mkQ()
        let a = note("Same", body: "text", app: "App")
        _ = q.accept(a, now: at(0))
        eq(dedupedID(q.accept(note("Same", body: "text", app: "App"), now: at(1))) ?? UUID(), a.id, "identical notifications without a key are merged")
        check(queuedPos(q.accept(note("Same", body: "different", app: "App"), now: at(1))) != nil, "a different body is a different notification")
        check(queuedPos(q.accept(note("Same", body: "text", app: "Other"), now: at(1))) != nil, "a different app is a different notification")
        check(queuedPos(q.accept(note("Same", body: "text", app: "App", thread: "t1"), now: at(1))) != nil, "a different thread is a different notification")
    }
    do {
        var q = mkQ()
        let a = note("same", app: "a", source: .cli, key: "k")
        _ = q.accept(a, now: at(0))
        check(queuedPos(q.accept(note("same", app: "a", source: .atoll, key: "k"), now: at(0))) != nil, "the same key from another source does not collide")
        var q2 = mkQ()
        _ = q2.accept(note("v1", key: "k"), now: at(0))
        check(dedupedID(q2.accept(note("v2", key: "k\u{200B}"), now: at(0))) != nil, "keys are sanitised before comparison (zero-width stripped)")
        var q3 = mkQ { $0.maxQueue = 2 }
        _ = q3.accept(note("cur", priority: .critical, ttl: 300), now: at(0))
        _ = q3.accept(note("p1", key: "1"), now: at(0)); _ = q3.accept(note("p2", key: "2"), now: at(0))
        check(dedupedID(q3.accept(note("p1b", key: "1"), now: at(0))) != nil, "replacing into a full queue is a dedupe, not a drop")
        eq(q3.queuedCount, 2, "...and the queue size is unchanged")
        var q4 = mkQ()
        let id = UUID()
        var m1 = note("a", key: "1"); m1.id = id
        var m2 = note("b", key: "2"); m2.id = id
        _ = q4.accept(m1, now: at(0)); _ = q4.accept(m2, now: at(0))
        check(q4.pending.first!.id != q4.current!.id, "a re-used notification id is replaced with a fresh one")
    }
    section("Queue: per-source rate limit")
    do {
        var q = mkQ { $0.rateLimitPerMinute = 3 }
        for i in 0..<3 { check(q.accept(note("n\(i)"), now: at(Double(i))) != .rateLimited, "rate limit: notification \(i + 1) of 3 admitted") }
        eq(q.accept(note("n3"), now: at(5)), .rateLimited, "fourth inside a minute is rate limited")
        eq(q.accept(note("n3"), now: at(59)), .rateLimited, "still limited at 59 s")
        check(q.accept(note("other", source: .atoll), now: at(5)) != .rateLimited, "another source has its own budget")
        check(q.accept(note("n3"), now: at(60.5)) != .rateLimited, "the window slides")
    }
    do {
        var q = mkQ { $0.rateLimitPerMinute = 2 }
        _ = q.accept(note("a"), now: at(0)); _ = q.accept(note("b"), now: at(0))
        var admitted = 0
        for i in 0..<8 where q.accept(note("c\(i)", priority: .critical), now: at(1)) != .rateLimited { admitted += 1 }
        eq(admitted, 6, "critical gets 4x the ceiling (8 total, 2 already used)")
        eq(q.accept(note("c", priority: .critical), now: at(1)), .rateLimited, "...but not unlimited")
    }
    do {
        var q = mkQ { $0.rateLimitPerMinute = 0 }
        var limited = 0
        for i in 0..<300 where q.accept(note("n\(i)"), now: at(0)) == .rateLimited { limited += 1 }
        eq(limited, 0, "rateLimitPerMinute 0 means unlimited")
        var q2 = mkQ { $0.rateLimitPerMinute = 1 }
        _ = q2.accept(note(""), now: at(0))
        check(q2.accept(note("valid"), now: at(0)) != .rateLimited, "invalid content does not consume the rate budget")
        var q3 = mkQ { $0.rateLimitPerMinute = 2 }
        _ = q3.accept(note("same"), now: at(0)); _ = q3.accept(note("same"), now: at(0))
        eq(q3.accept(note("different"), now: at(0)), .rateLimited, "duplicates count against the budget (they cost work)")
    }
    section("Queue: cap and eviction")
    do {
        var q = mkQ { $0.maxQueue = 3 }
        _ = q.accept(note("cur", priority: .critical, ttl: 300), now: at(0))
        _ = q.accept(note("P1", priority: .low), now: at(0))
        _ = q.accept(note("P2", priority: .normal), now: at(0))
        _ = q.accept(note("P3", priority: .low), now: at(0))
        let d = q.accept(note("P4", priority: .normal), now: at(0))
        check(queuedPos(d) != nil, "incoming normal is queued when it can evict a low")
        eq(pendingTitles(q), ["P2", "P4", "P3"], "the OLDEST LOWEST-priority item (P1) was evicted")
        eq(q.history.first?.display.title ?? "", "P1", "evicted item is in history")
        eq(q.history.first?.outcome ?? .dismissed, .evicted, "...as evicted")
        check(q.history.first?.wasShown == false, "...never shown")
    }
    do {
        var q = mkQ { $0.maxQueue = 2 }
        _ = q.accept(note("cur", priority: .critical, ttl: 300), now: at(0))
        _ = q.accept(note("n1"), now: at(0)); _ = q.accept(note("n2"), now: at(0))
        eq(q.accept(note("low", priority: .low), now: at(0)), .dropped(.queueFull), "incoming lowest-priority into a full queue is dropped")
        eq(q.history.first?.display.title ?? "", "low", "...and recorded as evicted")
        _ = q.accept(note("n3"), now: at(0))
        eq(pendingTitles(q), ["n2", "n3"], "equal priority: the oldest is evicted, the newcomer stays")
    }
    do {
        var q = mkQ { $0.maxQueue = 2 }
        _ = q.accept(note("cur", priority: .critical, ttl: 300), now: at(0))
        _ = q.accept(note("low1", priority: .low), now: at(0)); _ = q.accept(note("low2", priority: .low), now: at(0))
        _ = q.accept(note("norm1"), now: at(0))
        _ = q.accept(note("norm2"), now: at(0))
        _ = q.accept(note("high1", priority: .high), now: at(0))
        eq(q.history.filter { $0.outcome == .evicted }.map { $0.display.title }.reversed(), ["low1", "low2", "norm1"], "eviction order: lows (oldest first), then the oldest normal")
        eq(pendingTitles(q), ["high1", "norm2"], "survivors")
    }
    do {  // critical is never dropped
        var q = mkQ { $0.maxQueue = 2 }
        _ = q.accept(note("cur", priority: .critical, ttl: 300), now: at(0))
        for i in 0..<5 { check(queuedPos(q.accept(note("crit\(i)", priority: .critical), now: at(0))) != nil, "critical #\(i + 1) is never dropped by the cap") }
        eq(q.queuedCount, 5, "criticals may exceed the cap")
        eq(q.accept(note("normal"), now: at(0)), .dropped(.queueFull), "a non-critical newcomer loses against a queue of criticals")
        var q2 = mkQ { $0.maxQueue = 3 }
        _ = q2.accept(note("cur", priority: .critical, ttl: 300), now: at(0))
        _ = q2.accept(note("c1", priority: .critical), now: at(0)); _ = q2.accept(note("c2", priority: .critical), now: at(0))
        _ = q2.accept(note("l", priority: .low), now: at(0))
        _ = q2.accept(note("c3", priority: .critical), now: at(0))
        eq(pendingTitles(q2), ["c1", "c2", "c3"], "a critical newcomer evicts a non-critical, never a critical")
        check(!q2.history.contains { $0.outcome == .evicted && $0.display.priority == .critical }, "no critical was evicted")
        var q3 = mkQ { $0.maxQueue = 0 }
        _ = q3.accept(note("a"), now: at(0))
        eq(q3.accept(note("b"), now: at(0)), .dropped(.queueFull), "maxQueue 0: only the current slot exists")
        var q4 = mkQ { $0.maxQueue = 5 }
        _ = q4.accept(note("cur", priority: .critical, ttl: 300), now: at(0))
        for i in 0..<5 { _ = q4.accept(note("n\(i)"), now: at(0)) }
        q4.settings.maxQueue = 2
        _ = q4.accept(note("new"), now: at(0))
        eq(q4.queuedCount, 2, "shrinking maxQueue is enforced on the next accept")
    }
    section("Queue: Focus policy")
    do {
        let focus = Atomic(true)
        let calls = Atomic(0)
        var q = NotificationQueue(settings: enabledSettings { $0.focusPolicy = .silence }, isFocusActive: { calls.mutate { $0 += 1 }; return focus.get() }, fileExists: { _ in true })
        let a = note("normal")
        check(silencedID(q.accept(a, now: at(0))) == a.id, "silence: a normal notification is silenced")
        check(silencedID(q.accept(note("crit", priority: .critical), now: at(0))) != nil, "silence: even critical is silenced")
        check(q.current == nil && q.pending.isEmpty, "silenced items are never shown or queued")
        check(q.history.count == 2 && q.history.allSatisfy { $0.isSilenced && !$0.wasShown }, "silenced items are in history with the flag, not shown")
        check(silencedID(q.accept(note("normal"), now: at(1))) == nil && q.history.count == 2, "a repeated silenced notification is deduped, not recorded twice")
        focus.set(false)
        check(shownID(q.accept(note("later"), now: at(2))) != nil, "Focus off: shown")
        var q2 = NotificationQueue(settings: enabledSettings { $0.focusPolicy = .silenceExceptCritical }, isFocusActive: { true }, fileExists: { _ in true })
        check(silencedID(q2.accept(note("n"), now: at(0))) != nil, "silenceExceptCritical: normal silenced")
        check(silencedID(q2.accept(note("h", priority: .high), now: at(0))) != nil, "silenceExceptCritical: high silenced")
        check(silencedID(q2.accept(note("l", priority: .low), now: at(0))) != nil, "silenceExceptCritical: low silenced")
        check(shownID(q2.accept(note("c", priority: .critical), now: at(0))) != nil, "silenceExceptCritical: critical shown")
        let calls2 = Atomic(0)
        var q3 = NotificationQueue(settings: enabledSettings { $0.focusPolicy = .show }, isFocusActive: { calls2.mutate { $0 += 1 }; return true }, fileExists: { _ in true })
        check(shownID(q3.accept(note("n"), now: at(0))) != nil, "show: Focus is ignored")
        eq(calls2.get(), 0, "show: Focus is not even queried")
        var q4 = NotificationQueue(settings: enabledSettings { $0.focusPolicy = .silenceExceptCritical }, isFocusActive: { false }, fileExists: { _ in true })
        check(shownID(q4.accept(note("n"), now: at(0))) != nil, "Focus inactive: shown")
        var q5 = NotificationQueue(settings: enabledSettings { $0.focusPolicy = .silence; $0.privacyMode = .hideAll }, isFocusActive: { true }, fileExists: { _ in true })
        _ = q5.accept(note("SECRETTITLE7", body: "SECRETBODY8", app: "Mail"), now: at(0))
        check(!allText(q5.history[0].display).contains("SECRETTITLE7") && !allText(q5.history[0].display).contains("SECRETBODY8"), "silenced history entries are redacted too")
        check(calls.get() >= 1, "Focus is consulted through the injected closure")
    }
    section("Queue: privacy redaction (no hidden substring may reach any output)")
    do {
        let title = "Tq9VlmZ", sub = "Sx7KPw3Z", body = "Bz4nRy8Wd"
        func run(_ mode: NotificationPrivacyMode, sensitive: Bool = false) -> NotificationQueue {
            var q = mkQ { $0.privacyMode = mode }
            _ = q.accept(note(title, body: body, subtitle: sub, app: "Mail", sensitive: sensitive, symbol: "envelope.fill", bundle: "com.apple.mail"), now: at(0))
            return q
        }
        let off = run(.off).current!.display
        check(off.title == title && off.subtitle == sub && off.body == body && !off.isRedacted, "off: everything shown")
        let hp = run(.hidePreview)
        let d = hp.current!.display
        check(d.title == title && d.subtitle == nil && d.body == nil && d.isRedacted, "hidePreview: title kept, subtitle and body removed")
        check(!allText(d).contains(sub) && !allText(d).contains(body), "hidePreview: neither hidden field appears in any output field")
        let ha = run(.hideAll)
        let da = ha.current!.display
        eq(da.title, "Notification from Mail", "hideAll: generic title naming the app")
        check(da.subtitle == nil && da.body == nil && da.isRedacted, "hideAll: no subtitle or body")
        check(!allText(da).contains(title) && !allText(da).contains(sub) && !allText(da).contains(body), "hideAll: no hidden field appears in any output field")
        check(da.iconSymbol == "envelope.fill" && da.bundleID == "com.apple.mail", "hideAll keeps the icon identity")
        let so = run(.off, sensitive: true).current!.display
        check(so.isRedacted && so.subtitle == nil && so.body == nil && so.title == title, "isSensitive forces at least hidePreview")
        let sh = run(.hideAll, sensitive: true).current!.display
        eq(sh.title, "Notification from Mail", "isSensitive never loosens hideAll")
        let sp = run(.hidePreview, sensitive: true).current!.display
        check(sp.isRedacted && sp.body == nil, "isSensitive with hidePreview stays hidePreview")
        // The queue itself must not retain raw text.
        for (mode, hidden) in [(NotificationPrivacyMode.hidePreview, [sub, body]), (.hideAll, [title, sub, body])] {
            var q = mkQ { $0.privacyMode = mode }
            _ = q.accept(note("cur", priority: .critical, ttl: 300), now: at(0))
            _ = q.accept(note(title, body: body, subtitle: sub, app: "Mail"), now: at(0))
            _ = q.accept(note("silent2", body: body, subtitle: sub), now: at(0))
            q.dismissAll(now: at(1))
            _ = q.accept(note(title, body: body, subtitle: sub, app: "Mail"), now: at(2))
            let dump = String(reflecting: q.current) + String(reflecting: q.pending) + String(reflecting: q.history)
            check(!hidden.contains { dump.contains($0) }, "\(mode): current/pending/history hold no hidden text (reflected dump)")
        }
        // Silenced by Focus never carries hidden text either (checked above); now the decision values.
        var qd = mkQ { $0.privacyMode = .hideAll }
        let dec = qd.accept(note(title, body: body, subtitle: sub), now: at(0))
        check(!"\(dec)".contains(title) && !"\(dec)".contains(body), "decisions carry only ids")
        // Seeded random strings: no 4-gram of a hidden field may appear anywhere in the output.
        var rng = SplitMix64(seed: 7)
        let alphabet = Array("QXZJVKWY0123456789")
        func rnd(_ n: Int) -> String { String((0..<n).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }) }
        var leaks = 0, runs = 0
        for _ in 0..<60 {
            let t = rnd(14), s = rnd(14), b = rnd(30)
            for mode in [NotificationPrivacyMode.hidePreview, .hideAll] {
                var q = mkQ { $0.privacyMode = mode }
                _ = q.accept(note(t, body: b, subtitle: s, app: "Mail"), now: at(0))
                let out = allText(q.current!.display)
                runs += 1
                if leaksNGram(s, in: out) || leaksNGram(b, in: out) { leaks += 1 }
                if mode == .hideAll, leaksNGram(t, in: out) { leaks += 1 }
            }
        }
        eq(leaks, 0, "random-string leak scan: 0 leaks in \(runs) redactions")
        var qm = mkQ { $0.privacyMode = .hidePreview }
        _ = qm.accept(note("cur", priority: .critical, ttl: 300), now: at(0))
        _ = qm.accept(note("q", body: "queuedBodyZ9"), now: at(0))
        qm.settings.privacyMode = .off
        check(qm.pending[0].display.body == nil, "redaction happens at accept time: a queued item stays redacted if the mode loosens later")
    }
    section("Queue: validated actions and ids")
    do {
        var q = mkQ()
        func hasAction(_ a: NotificationAction) -> Bool { var qq = mkQ(); _ = qq.accept(note("a", action: a), now: at(0)); return qq.current!.display.hasAction }
        check(!hasAction(.none), "no action: hasAction false")
        check(hasAction(.openURL(URL(string: "https://example.com/x")!)), "https action: hasAction true")
        check(!hasAction(.openURL(URL(string: "javascript:alert(1)")!)), "javascript: URL is stripped (hasAction false)")
        check(!hasAction(.openURL(URL(string: "data:text/html,hi")!)), "data: URL is stripped")
        check(hasAction(.activateApp(bundleID: "com.apple.Terminal")), "valid bundle id keeps the action")
        check(!hasAction(.activateApp(bundleID: "not a bundle")), "invalid bundle id is stripped")
        check(hasAction(.openNotchTab("agents")), "valid tab keeps the action")
        check(!hasAction(.openNotchTab("a b/c")), "invalid tab is stripped")
        check(hasAction(.openAgentSession("sess-1")), "agent session action kept")
        check(!hasAction(.openAgentSession("\u{200B}")), "empty agent session id is stripped")
        var q2 = NotificationQueue(settings: enabledSettings(), isFocusActive: { false }, fileExists: { _ in false })
        _ = q2.accept(note("a", action: .openURL(URL(fileURLWithPath: "/etc/hosts"))), now: at(0))
        check(!q2.current!.display.hasAction, "file URL to a non-existent path is stripped")
        let n = note("ts"); var late = n; late.receivedAt = Date(timeIntervalSince1970: 5)
        _ = q.accept(late, now: at(0)); _ = q.dismiss(id: late.id, now: at(1))
        eq(q.history.first?.receivedAt ?? .distantPast, at(0), "receivedAt comes from the queue's clock, not the sender")
        let a = note("u", action: .openURL(URL(string: "https://example.com")!))
        _ = q.accept(a, now: at(2))
        eq(q.action(for: a.id) ?? .none, .openURL(URL(string: "https://example.com")!), "action(for:) finds a live item")
        _ = q.dismiss(id: a.id, outcome: .actioned, now: at(3))
        eq(q.action(for: a.id) ?? .none, .openURL(URL(string: "https://example.com")!), "action(for:) finds an item in history")
        check(q.action(for: UUID()) == nil, "action(for:) of an unknown id is nil")
    }
    section("Queue: dismiss, purge, history")
    do {
        var q = mkQ()
        let a = note("a"), b = note("b"), c = note("c", source: .atoll)
        _ = q.accept(a, now: at(0)); _ = q.accept(b, now: at(0)); _ = q.accept(c, now: at(0))
        check(q.dismiss(id: a.id, now: at(1)), "dismiss current")
        eq(q.current?.display.title ?? "", "b", "dismissing the current item promotes the next")
        eq(q.nextDeadline ?? .distantPast, at(5), "...with a full TTL")
        check(q.dismiss(id: c.id, now: at(1)), "dismiss a queued item")
        check(!q.dismiss(id: UUID(), now: at(1)), "dismiss of an unknown id is false")
        check(!q.dismiss(id: a.id, now: at(1)), "dismiss twice is false")
        eq(q.history.first?.outcome ?? .expired, .dismissed, "dismissed outcome")
        var q2 = mkQ()
        for i in 0..<4 { _ = q2.accept(note("n\(i)", source: i % 2 == 0 ? .cli : .atoll), now: at(0)) }
        q2.purge(source: .cli, now: at(1))
        check(q2.current?.source == .atoll && q2.pending.allSatisfy { $0.source == .atoll }, "purge(source:) removes only that source and promotes")
        q2.dismissAll(now: at(2))
        check(q2.isIdle, "dismissAll empties the queue")
        check(q2.history.prefix(2).allSatisfy { $0.outcome == .cleared }, "dismissAll records cleared")
        var q3 = mkQ { $0.historyLimit = 3 }
        for i in 0..<5 { _ = q3.accept(note("h\(i)"), now: at(Double(i * 10))); q3.advance(now: at(Double(i * 10 + 5))) }
        eq(q3.history.map { $0.display.title }, ["h4", "h3", "h2"], "history ring keeps the newest historyLimit items")
        q3.settings.historyLimit = 1
        eq(q3.history.count, 1, "lowering historyLimit trims immediately")
        q3.settings.historyLimit = 0
        _ = q3.accept(note("zz"), now: at(100)); q3.advance(now: at(110))
        check(q3.history.isEmpty, "historyLimit 0 keeps nothing")
        var q4 = mkQ()
        _ = q4.accept(note("x"), now: at(0)); q4.advance(now: at(5))
        q4.clearHistory()
        check(q4.history.isEmpty, "clearHistory")
    }
    section("Queue: determinism and invariants (seeded fuzz)")
    do {
        func script(_ seed: UInt64) -> (decisions: [String], state: String, invariantFailures: Int) {
            var rng = SplitMix64(seed: seed)
            var q = mkQ(focus: false) { $0.maxQueue = 4; $0.rateLimitPerMinute = 50; $0.historyLimit = 20 }
            var now = t0
            var out: [String] = []
            var bad = 0
            for i in 0..<400 {
                now = now.addingTimeInterval(Double(rng.next() % 3000) / 1000)
                switch rng.next() % 10 {
                case 0..<6:
                    var n = note("t\(rng.next() % 12)", priority: NotificationPriority(rawValue: Int(rng.next() % 4))!, ttl: rng.next() % 4 == 0 ? Double(rng.next() % 8) : nil,
                                 key: rng.next() % 3 == 0 ? "k\(rng.next() % 5)" : nil)
                    n.id = detID(i)
                    out.append("\(q.accept(n, now: now))")
                case 6: q.advance(now: now)
                case 7: if let c = q.current { _ = q.dismiss(id: c.id, now: now) }
                case 8: q.setPaused(rng.next() % 2 == 0, now: now)
                default: q.advance(now: now)
                }
                let sorted = q.pending == q.pending.sorted { a, b in a.priority != b.priority ? a.priority > b.priority : a.arrival < b.arrival }
                if q.current == nil && !q.pending.isEmpty { bad += 1 }
                if !sorted { bad += 1 }
                let ids = (q.current.map { [$0.id] } ?? []) + q.pending.map { $0.id }
                if Set(ids).count != ids.count { bad += 1 }
                if q.history.count > 20 { bad += 1 }
                if q.pending.count > 4, q.pending.contains(where: { $0.priority != .critical }) { bad += 1 }
                if q.current != nil, q.isPaused, q.nextDeadline != nil { bad += 1 }
            }
            return (out, "\(q.current as Any)|\(q.pending)|\(q.history)", bad)
        }
        var totalBad = 0
        for seed in [1, 2, 3, 4, 5, 6] as [UInt64] {
            let a = script(seed), b = script(seed)
            totalBad += a.invariantFailures
            check(a.decisions == b.decisions && a.state == b.state, "fuzz seed \(seed): two runs are identical (deterministic)")
        }
        eq(totalBad, 0, "fuzz invariants hold over 6 x 400 operations (idle => no pending, sorted, unique ids, caps, paused => no deadline)")
    }
}
