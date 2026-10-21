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

// T2: SneakPeekScheduler. Scenario regressions for audit bugs B2-B6 and B10, the rules of audit 2.7, and a seeded fuzz of
// >= 100,000 event sequences checking the invariants after every single operation. The clock is injected (a Double the
// test advances), so nothing here sleeps.

private typealias Sched = SneakPeekScheduler<String>

private func req(_ key: String, _ rank: NotchSurfaceRank, sub: Int = 0, ttl: TimeInterval) -> SneakPeekRequest<String> {
    SneakPeekRequest(dedupeKey: key, rank: rank, subrank: sub, ttl: ttl, payload: key)
}

private func near(_ a: TimeInterval?, _ b: TimeInterval) -> Bool {
    guard let a else { return false }
    return abs(a - b) < 1e-9
}

private func liveTokens(_ s: Sched) -> Set<SneakPeekToken> {
    var set = Set(s.queue.map(\.token))
    if let a = s.active { set.insert(a.token) }
    return set
}

func arbRunSchedulerScenarios() {
    arbSection("Scheduler scenarios (audit 2.6)")

    // B2: volume key and Caps Lock in the same turn used to share ONE duration field and wedge the HUD forever.
    do {
        var s = Sched()
        s.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 0)
        let caps = s.offer(req("caps", .systemHUD, sub: 2, ttl: .infinity), now: 0)
        arbEqual("B2: an infinite ttl is a STICKY item and is never scheduled", caps.outcome, .rejected(.stickyNotScheduled))
        arbEqual("B2: volume HUD is current", s.active?.payload, "volume")
        s.expire(now: 1.49)
        arbEqual("B2: still showing at 1.49 s", s.active?.payload, "volume")
        s.expire(now: 1.5)
        arbCheck("B2: volume HUD hides at its own 1.5 s, nothing wedged", s.active == nil && s.nextDeadline == nil && s.pendingCount == 0)
    }
    do {
        var s = Sched()
        s.offer(req("caps", .systemHUD, sub: 2, ttl: .infinity), now: 0)
        s.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 0)
        s.expire(now: 1.5)
        arbCheck("B2 (reverse order): sticky first, volume still hides on time", s.active == nil)
    }
    do {
        var s = Sched()
        s.offer(req("bt", .systemHUD, sub: 0, ttl: 2.5), now: 0)
        s.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 0)
        arbCheck("B2: each item keeps its own ttl (no shared duration field)", near(s.nextDeadline, 2.5) && s.queue.first?.ttl == 1.5)
        s.expire(now: 2.5)
        arbCheck("B2: the queued item starts at the logical instant the first ended, with its own ttl",
                 s.active?.payload == "volume" && near(s.nextDeadline, 4.0))
        s.expire(now: 100)
        arbCheck("B2: everything ends", s.active == nil && s.pendingCount == 0)
    }

    // B3: a Bluetooth HUD must survive a Caps Lock OFF hide.
    do {
        var s = Sched()
        let bt = s.offer(req("bluetooth", .systemHUD, sub: 0, ttl: 2.5), now: 0)
        let u1 = s.finish(dedupeKey: "caps", now: 0.5)
        arbCheck("B3: hide for another type is a no-op", u1.outcome == .noop && s.active?.payload == "bluetooth")
        let u2 = s.finish(token: SneakPeekToken(9_999), now: 0.6)
        arbCheck("B3: hide with a foreign token is a no-op", u2.outcome == .noop && s.active?.payload == "bluetooth")
        let u3 = s.finish(token: bt.token!, now: 0.7)
        arbCheck("B3: hide with the matching token works", u3.outcome == .finished && s.active == nil)
    }

    // B4: turning "System HUD" off while a HUD is up used to drop the scheduled hide (gating applies to OFFERS only).
    do {
        var s = Sched()
        s.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 0)
        // The integration gates `offer`; nothing in the scheduler can swallow expiry or finish.
        s.expire(now: 1.5)
        arbCheck("B4: expiry is independent of any enable flag", s.active == nil)
        var s2 = Sched()
        let u2 = s2.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 0)
        arbCheck("B4: finish(token) always works", s2.finish(token: u2.token!, now: 0.2).outcome == .finished && s2.active == nil)
    }

    // B5: the hide timer waking at the exact moment a new HUD is applied flashed the new one away.
    do {
        var base = Sched()
        let first = base.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 0)
        var expireFirst = base, offerFirst = base
        expireFirst.expire(now: 1.5)
        expireFirst.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 1.5)
        offerFirst.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 1.5)
        arbCheck("B5: wake-then-offer and offer-then-wake end in the identical state", expireFirst == offerFirst)
        arbCheck("B5: the new HUD gets its full ttl (no flash)", near(offerFirst.nextDeadline, 3.0) && offerFirst.active?.token != first.token)
        let stale = offerFirst.finish(token: first.token!, now: 1.5)
        arbCheck("B5: the OLD timer's hide (stale token) cannot hide the new HUD", stale.outcome == .noop && offerFirst.active != nil)
        let stale2 = offerFirst.expire(now: 1.5)
        arbCheck("B5: a stale wake at the old deadline changes nothing", stale2.outcome == .noop && offerFirst.active != nil)
        // replaced BEFORE the old deadline
        var r = Sched()
        let t1 = r.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 0)
        let t2 = r.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 1.4)
        arbCheck("B5: same key replaces: new token, ttl restarted, old token superseded",
                 t2.outcome == .replacedActive && t2.superseded == [t1.token!] && near(r.nextDeadline, 2.9))
        arbCheck("B5: stale finish after replace is a no-op", r.finish(token: t1.token!, now: 1.5).outcome == .noop && r.active?.token == t2.token)
    }

    // B6: AirPods connect HUD (2.5 s) was cut short by a volume press at 1.6 s.
    do {
        var s = Sched()
        s.offer(req("bluetooth", .systemHUD, sub: 0, ttl: 2.5), now: 0)
        let v = s.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 1.6)
        arbCheck("B6: volume press does NOT preempt the Bluetooth HUD", v.outcome == .queued && s.active?.payload == "bluetooth")
        s.expire(now: 2.49)
        arbEqual("B6: Bluetooth HUD still up at 2.49 s", s.active?.payload, "bluetooth")
        s.expire(now: 2.5)
        arbCheck("B6: volume HUD follows with its full ttl", s.active?.payload == "volume" && near(s.nextDeadline, 4.0))
        // repeated presses coalesce
        var c = Sched()
        c.offer(req("bluetooth", .systemHUD, sub: 0, ttl: 2.5), now: 0)
        for i in 1...5 { c.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 0.2 * Double(i)) }
        arbEqual("B6: five volume presses coalesce into one queued item", c.pendingCount, 1)
    }

    // B10: a critical reminder was overwritten by any later extension activity.
    do {
        var s = Sched()
        s.offer(req("reminder", .criticalAlert, ttl: 5), now: 0)
        let e = s.offer(req("ext", .appNotification, sub: 1, ttl: 2.5), now: 1)
        arbCheck("B10: extension activity cannot overwrite the critical reminder", e.outcome == .queued && s.active?.payload == "reminder")
        s.expire(now: 5)
        arbCheck("B10: it waits, then shows with its full ttl", s.active?.payload == "ext" && near(s.nextDeadline, 7.5))
        var p = Sched()
        p.offer(req("ext", .appNotification, sub: 1, ttl: 2.5), now: 0)
        let c = p.offer(req("reminder", .criticalAlert, ttl: 5), now: 1)
        arbCheck("B10: critical preempts a normal extension activity", c.outcome == .showing && p.active?.payload == "reminder")
        arbCheck("B10: the preempted item keeps remaining 1.5 s", near(p.queue.first?.remaining, 1.5))
        p.finish(token: c.token!, now: 6)
        arbCheck("B10: it resumes with exactly its remaining ttl", p.active?.payload == "ext" && near(p.nextDeadline, 7.5))
        p.expire(now: 7.49)
        arbEqual("B10: still showing just before the end", p.active?.payload, "ext")
        p.expire(now: 7.5)
        arbCheck("B10: and ends on time", p.active == nil)
    }

    arbSection("Scheduler rules (audit 2.7 determinism rules 3-5)")
    do {
        var s = Sched()
        s.offer(req("note", .appNotification, sub: 1, ttl: 5), now: 0)
        s.offer(req("volume", .systemHUD, sub: 1, ttl: 1.5), now: 2)
        arbCheck("preempt: rank 6 preempts rank 7; the note keeps 3 s", s.active?.payload == "volume" && near(s.queue.first?.remaining, 3))
        s.expire(now: 3.5)
        arbCheck("resume: note resumes at 3.5 with 3 s left", s.active?.payload == "note" && near(s.nextDeadline, 6.5))
        s.expire(now: 6.5)
        arbCheck("resume: ends at 6.5", s.active == nil)

        var chain = Sched()
        chain.offer(req("n", .appNotification, ttl: 10), now: 0)
        chain.offer(req("h", .systemHUD, ttl: 4), now: 1)
        chain.offer(req("c", .criticalAlert, ttl: 3), now: 2)
        arbCheck("nested preemption: critical > hud > note", chain.active?.payload == "c" && chain.queue.map(\.payload) == ["h", "n"])
        chain.expire(now: 5)
        arbCheck("critical ends; HUD resumes with 3 s", chain.active?.payload == "h" && near(chain.nextDeadline, 8))
        chain.expire(now: 8)
        arbCheck("HUD ends; note resumes with its 9 s", chain.active?.payload == "n" && near(chain.nextDeadline, 17))
    }
    do {
        var s = Sched()
        s.offer(req("a", .appNotification, sub: 1, ttl: 3), now: 0)
        s.offer(req("b", .appNotification, sub: 1, ttl: 3), now: 0)
        s.offer(req("c", .appNotification, sub: 1, ttl: 3), now: 0)
        s.offer(req("d", .appNotification, sub: 0, ttl: 3), now: 0)   // high priority notification jumps the QUEUE, not the active item
        arbCheck("equal rank never preempts; subrank orders the queue; FIFO within a subrank",
                 s.active?.payload == "a" && s.queue.map(\.payload) == ["d", "b", "c"])
        var order: [String] = []
        var now = 0.0
        while let a = s.active { order.append(a.payload); now = s.nextDeadline!; s.expire(now: now) }
        arbEqual("display order is a, d, b, c", order, ["a", "d", "b", "c"])
    }
    do {
        var s = Sched()
        s.offer(req("a", .appNotification, sub: 1, ttl: 3), now: 0)
        s.offer(req("b", .appNotification, sub: 1, ttl: 3), now: 0)
        let b0 = s.queue[0].key.arrivalSeq
        let u = s.offer(req("b", .appNotification, sub: 1, ttl: 8), now: 1)
        arbCheck("dedupe in the queue replaces: new token, ttl updated, position (arrivalSeq) kept",
                 u.outcome == .replacedQueued && s.pendingCount == 1 && s.queue[0].ttl == 8 && s.queue[0].key.arrivalSeq == b0 && u.superseded.count == 1)
    }
    do {
        // cap: default 5, lowest priority then oldest evicted
        var s = Sched()
        arbEqual("default capacity is 5", s.capacity, 5)
        s.offer(req("active", .criticalAlert, ttl: 60), now: 0)
        for i in 1...5 { s.offer(req("n\(i)", .appNotification, sub: 1, ttl: 5), now: 0) }
        arbEqual("queue holds 5", s.pendingCount, 5)
        let u = s.offer(req("n6", .appNotification, sub: 1, ttl: 5), now: 0)
        arbCheck("overflow with equal rank drops the OLDEST (n1) and keeps the newcomer",
                 u.outcome == .queued && s.pendingCount == 5 && u.dropped.count == 1
                 && !s.queue.map(\.payload).contains("n1") && s.queue.map(\.payload).contains("n6"))
        let h = s.offer(req("hud", .systemHUD, sub: 1, ttl: 5), now: 0)
        arbCheck("a higher-rank newcomer evicts the lowest-priority item and sits at the head",
                 h.outcome == .queued && s.pendingCount == 5 && s.queue.first?.payload == "hud" && !s.queue.map(\.payload).contains("n2"))
        let low = s.offer(req("low", .appNotification, sub: 2, ttl: 5), now: 0)
        arbCheck("a newcomer worse than everything in a full queue is rejected", low.outcome == .rejected(.queueFull) && s.pendingCount == 5)
        var zero = Sched(capacity: 0)
        zero.offer(req("a", .systemHUD, ttl: 5), now: 0)
        let z = zero.offer(req("b", .systemHUD, ttl: 5), now: 0)
        arbCheck("capacity 0: nothing waits", z.outcome == .rejected(.queueFull) && zero.pendingCount == 0)
    }
    do {
        var s = Sched()
        arbEqual("zero ttl rejected", s.offer(req("a", .systemHUD, ttl: 0), now: 0).outcome, .rejected(.invalidTTL))
        arbEqual("negative ttl rejected", s.offer(req("a", .systemHUD, ttl: -3), now: 0).outcome, .rejected(.invalidTTL))
        arbEqual("NaN ttl rejected", s.offer(req("a", .systemHUD, ttl: .nan), now: 0).outcome, .rejected(.invalidTTL))
        arbEqual("infinite ttl (STICKY) never queued", s.offer(req("a", .systemHUD, ttl: .infinity), now: 0).outcome, .rejected(.stickyNotScheduled))
        arbCheck("rejections leave no state", s.active == nil && s.pendingCount == 0)
        let long = s.offer(req("a", .systemHUD, ttl: 1e9), now: 0)
        arbCheck("huge finite ttl is clamped to maxTTL (no state without a pending expiry)", long.outcome == .showing && near(s.nextDeadline, Sched.maxTTL))
        var p = Sched()
        p.offer(req("a", .systemHUD, ttl: 5), now: 10)
        p.expire(now: 3)
        arbCheck("time never moves backwards", p.clock == 10 && near(p.nextDeadline, 15))
        p.offer(req("b", .systemHUD, ttl: 5), now: .nan)
        arbCheck("a NaN clock is ignored", p.clock == 10)
    }
    do {
        var s = Sched()
        s.offer(req("a", .systemHUD, ttl: 5), now: 0)
        s.pause(now: 2)
        arbCheck("pause freezes the countdown: no deadline, 3 s left", s.isPaused && s.nextDeadline == nil && near(s.remaining(now: 100), 3))
        s.expire(now: 50)
        arbEqual("a paused item never expires", s.active?.payload, "a")
        s.resume(now: 60)
        arbCheck("resume restarts it with the remaining 3 s", near(s.nextDeadline, 63))
        s.offer(req("c", .criticalAlert, ttl: 2), now: 61)
        s.pause(now: 61.5)
        s.expire(now: 90)
        arbEqual("still the critical item while paused", s.active?.payload, "c")
        s.resume(now: 91)
        s.expire(now: 93)
        arbCheck("after resume the critical item ends at 92.5; the preempted one resumes THEN with its 2 s left (not 3): 94.5",
                 s.active?.payload == "a" && near(s.nextDeadline, 94.5))
        var all = Sched()
        all.offer(req("a", .systemHUD, ttl: 5), now: 0)
        all.offer(req("b", .systemHUD, ttl: 5), now: 0)
        let cu = all.clearAll(now: 1)
        arbCheck("clearAll drops everything (lock screen)", all.active == nil && all.pendingCount == 0 && cu.dropped.count == 2)
    }

    arbSection("Determinism and replay (fixed event list)")
    do {
        // Same arrival order, different dispatch timing of wake-ups: the outcome is identical.
        func run(extraTicks: Bool) -> Sched {
            var s = Sched()
            var rng = ArbRNG(seed: 77)
            var now = 0.0
            for i in 0..<400 {
                now += rng.pick([0, 0, 0.1, 0.4, 1.0, 2.0])
                if extraTicks, i % 3 == 0 { s.expire(now: now) }
                if extraTicks, i % 5 == 0 { s.expire(now: now) }
                let ranks: [(NotchSurfaceRank, Int)] = [(.systemHUD, 0), (.systemHUD, 1), (.appNotification, 1), (.criticalAlert, 0), (.battery, 0)]
                let r = rng.pick(ranks)
                s.offer(req("k\(rng.int(6))", r.0, sub: r.1, ttl: rng.pick([0.5, 1.5, 2.5, 5])), now: now)
            }
            s.expire(now: now + 1000)
            return s
        }
        arbCheck("replay and extra redundant expire() calls give the identical final state", run(extraTicks: false) == run(extraTicks: true) && run(extraTicks: false) == run(extraTicks: false))
    }
}

// MARK: - Fuzz

private let arbFuzzKeys = ["volume", "brightness", "bluetooth", "caps", "notifA", "notifB", "notifC", "ext", "reminder", "music", "battery"]
private let arbFuzzRanks: [(NotchSurfaceRank, Int)] = [
    (.battery, 0), (.criticalAlert, 0), (.systemHUD, 0), (.systemHUD, 1), (.systemHUD, 2), (.appNotification, 0), (.appNotification, 1), (.appNotification, 2),
]
private let arbFuzzTTLs: [TimeInterval] = [0.3, 0.8, 1.5, 2.5, 4, 5, 10]

private func invariantViolation(_ s: Sched, prevRemaining: inout [SneakPeekToken: TimeInterval]) -> String? {
    if s.queue.count > s.capacity { return "queue \(s.queue.count) exceeds capacity \(s.capacity)" }
    var tokens = Set<SneakPeekToken>(), keys = Set<String>()
    var all = s.queue
    if let a = s.active { all.insert(a, at: 0) }
    for i in all {
        if !tokens.insert(i.token).inserted { return "duplicate token \(i.token)" }
        if !keys.insert(i.dedupeKey).inserted { return "duplicate dedupe key \(i.dedupeKey)" }
        if !i.ttl.isFinite || i.ttl <= 0 || i.ttl > Sched.maxTTL { return "bad ttl \(i.ttl)" }
    }
    if s.active == nil {
        if !s.queue.isEmpty { return "no active item but \(s.queue.count) waiting (promotion lost)" }
        if s.nextDeadline != nil { return "deadline without an active item" }
    }
    if let a = s.active {
        if s.isPaused {
            if s.nextDeadline != nil { return "paused but a deadline is set" }
        } else {
            guard let d = s.nextDeadline else { return "show==true with no pending expiry: \(a.dedupeKey)" }
            if !(d > s.clock) { return "deadline \(d) not after clock \(s.clock)" }
        }
        if let b = s.queue.first, b.key.rank.position < a.key.rank.position { return "waiting item outranks the active one" }
    }
    for i in 1..<max(1, s.queue.count) where !(s.queue[i - 1].key < s.queue[i].key) { return "queue not sorted by key" }
    for i in all {
        let rem: TimeInterval = (i.token == s.active?.token) ? (s.remaining(now: s.clock) ?? i.remaining) : i.remaining
        if rem <= 0 || rem > i.ttl + 1e-9 { return "remaining \(rem) outside (0, ttl \(i.ttl)]" }
        if let p = prevRemaining[i.token], rem > p + 1e-9 { return "remaining grew for \(i.token): \(p) -> \(rem)" }
        prevRemaining[i.token] = rem
    }
    return nil
}

/// One random operation. Returns a violation description or nil.
private func fuzzStep(_ s: inout Sched, now: inout TimeInterval, rng: inout ArbRNG, issued: inout [SneakPeekToken],
                      prev: inout [SneakPeekToken: TimeInterval], check: Bool, ticks: [Double] = []) -> String? {
    let before = now
    now += rng.pick([0, 0, 0, 0.05, 0.2, 0.5, 1, 2, 6])
    // Redundant wake-ups between the previous event and this one (never later than this event: the clock is monotonic).
    for f in ticks { s.expire(now: before + f * (now - before)) }
    let op = rng.int(100)
    let live0 = liveTokens(s)
        var u = SneakPeekUpdate()
    var created: SneakPeekToken? = nil
    var bad: String? = nil

    func conserved(_ before: Set<SneakPeekToken>, _ after: Set<SneakPeekToken>, _ u: SneakPeekUpdate, _ created: SneakPeekToken?) -> Bool {
        let accounted = Set(u.expired).union(u.dropped).union(u.superseded)
        for t in before where !after.contains(t) && !accounted.contains(t) { return false }          // no silent loss
        for t in after where !before.contains(t) && t != created { return false }                    // no tokens from thin air
        return true
    }

    switch op {
    case 0..<55, 55..<58:
        let invalid = op >= 55
        let (rank, sub) = rng.pick(arbFuzzRanks)
        let ttl: TimeInterval = invalid ? rng.pick([0, -1, .nan, .infinity]) : rng.pick(arbFuzzTTLs)
        let key = rng.pick(arbFuzzKeys)
        u = s.offer(req(key, rank, sub: sub, ttl: ttl), now: now)
        created = u.token
        if let t = u.token { issued.append(t) }
        if check {
            if invalid {
                if u.token != nil { bad = "invalid ttl got a token" }
                if case .rejected = u.outcome {} else { bad = "invalid ttl accepted" }
            } else if let t = u.token {
                let live = liveTokens(s)
                switch u.outcome {
                case .rejected(.queueFull): if live.contains(t) { bad = "rejected item is live" }
                case .rejected: bad = "valid offer rejected for another reason"
                default: if !live.contains(t) { bad = "accepted item is not live" }
                }
                if u.outcome == .showing, s.active?.token != t { bad = "outcome showing but not active" }
            } else {
                bad = "valid offer produced no token"
            }
        }
    case 58..<66:       // finish with a live token
        s.expire(now: now)
        let before = liveTokens(s)
        if let t = before.sorted().randomElement(using: &rng) {
            u = s.finish(token: t, now: now)
            if check {
                if liveTokens(s) != before.subtracting([t]) { bad = "finish(token) removed something else" }
                if u.outcome != .finished { bad = "finish(live) outcome \(u.outcome)" }
            }
        }
        return bad ?? (check ? invariantViolation(s, prevRemaining: &prev) : nil)
    case 66..<72:       // finish with a STALE token: must change nothing at all
        s.expire(now: now)
        let live = liveTokens(s)
        let stale = issued.filter { !live.contains($0) }.randomElement(using: &rng) ?? SneakPeekToken(1 << 40)
        let copy = s
        u = s.finish(token: stale, now: now)
        if check, s != copy || u.outcome != .noop { bad = "stale token changed state (hide needs the matching token)" }
        return bad ?? (check ? invariantViolation(s, prevRemaining: &prev) : nil)
    case 72..<78:       // finish by key: only the item with exactly that key may go
        s.expire(now: now)
        let key = rng.pick(arbFuzzKeys)
        var expected: SneakPeekToken? = nil
        if let a = s.active, a.dedupeKey == key { expected = a.token }
        else if let q = s.queue.first(where: { $0.dedupeKey == key }) { expected = q.token }
        let before = liveTokens(s)
        u = s.finish(dedupeKey: key, now: now)
        if check {
            let after = liveTokens(s)
            if after != (expected.map { before.subtracting([$0]) } ?? before) { bad = "finish(dedupeKey:) removed the wrong item" }
        }
        return bad ?? (check ? invariantViolation(s, prevRemaining: &prev) : nil)
    case 78..<90:
        u = s.expire(now: now)
    case 90..<95:
        u = s.pause(now: now)
    case 95..<99:
        u = s.resume(now: now)
    default:
        u = s.clearAll(now: now)
        if check, s.active != nil || s.pendingCount != 0 { bad = "clearAll left state behind" }
    }
    if !check { return nil }
    if bad == nil, !conserved(live0, liveTokens(s), u, created) { bad = "token accounting broken: \(u)" }
    return bad ?? invariantViolation(s, prevRemaining: &prev)
}

func arbRunSchedulerFuzz() {
    arbSection("T2 fuzz: >= 100,000 event sequences, invariants checked after every operation")
    let seed: UInt64 = 0x5EED_0001
    let sequences = 100_000
    var ops = 0
    var maxQueue = 0
    var failures = 0
    var firstFailure = ""
    var sawPreemptResume = 0
    for n in 0..<sequences {
        var rng = ArbRNG(seed: seed &+ UInt64(n) &* 0x9E37_79B9_7F4A_7C15)
        let capacity = rng.int(10) == 0 ? rng.int(7) : 5
        var s = Sched(capacity: capacity)
        var now = 0.0
        var issued: [SneakPeekToken] = []
        var prev: [SneakPeekToken: TimeInterval] = [:]
        let count = 8 + rng.int(48)
        for _ in 0..<count {
            ops += 1
            if let v = fuzzStep(&s, now: &now, rng: &rng, issued: &issued, prev: &prev, check: true) {
                failures += 1
                if firstFailure.isEmpty { firstFailure = "seq \(n) op \(ops): \(v)\n   state: \(s)" }
                break
            }
            maxQueue = max(maxQueue, s.pendingCount)
            if s.active != nil, s.queue.contains(where: { $0.remaining < $0.ttl }) { sawPreemptResume += 1 }
        }
        prev.removeAll(keepingCapacity: true)
        if failures > 3 { break }
    }
    print("   seed \(String(seed, radix: 16)): \(sequences) sequences, \(ops) operations, max queue \(maxQueue), preempted-and-waiting states seen \(sawPreemptResume)")
    arbCheck("fuzz: one active item; hide needs the matching token; no show without expiry; remaining never grows; cap respected; sorted; no silent loss",
             failures == 0, firstFailure)
    arbCheck("fuzz: the preempt-and-resume path was actually exercised", sawPreemptResume > 10_000)
    arbCheck("fuzz: the queue was actually used (peak \(maxQueue)) and never exceeded its capacity", maxQueue >= 3)

    // Determinism: replay, and the same arrival order with redundant/extra wake-ups interleaved, must be bit-identical.
    do {
        var mismatches = 0
        var first = ""
        let runs = 20_000
        for n in 0..<runs {
            let base = 0xDE7E_0000 &+ UInt64(n)
            var a = Sched(), a2 = Sched(), b = Sched()
            var ra = ArbRNG(seed: base), ra2 = ArbRNG(seed: base), rb = ArbRNG(seed: base)
            var tick = ArbRNG(seed: base ^ 0xFFFF)
            var na = 0.0, na2 = 0.0, nb = 0.0
            var ia: [SneakPeekToken] = [], ia2: [SneakPeekToken] = [], ib: [SneakPeekToken] = []
            var pa: [SneakPeekToken: TimeInterval] = [:], pa2 = pa, pb = pa
            for step in 0..<(10 + Int(base % 30)) {
                // B receives extra expire() calls (late Task wakes, re-entrant ticks, duplicates) BEFORE each real event.
                var fractions: [Double] = []
                for _ in 0..<tick.int(4) { fractions.append(tick.pick([0, 0.25, 0.5, 0.999, 1])) }
                fractions.sort()
                _ = fuzzStep(&a, now: &na, rng: &ra, issued: &ia, prev: &pa, check: false)
                _ = fuzzStep(&a2, now: &na2, rng: &ra2, issued: &ia2, prev: &pa2, check: false)
                _ = fuzzStep(&b, now: &nb, rng: &rb, issued: &ib, prev: &pb, check: false, ticks: fractions)
                if a != a2 || a != b {
                    mismatches += 1
                    if first.isEmpty { first = "run \(n) step \(step)\n a: \(a)\n b: \(b)" }
                    break
                }
            }
        }
        arbCheck("determinism: identical state for replay and for permuted wake-up timing (\(runs) sequences)", mismatches == 0, first)
    }

    // Soak: no unbounded growth.
    do {
        var s = Sched()
        var rng = ArbRNG(seed: 4242)
        var now = 0.0
        var maxPending = 0
        let offers = 1_000_000
        for _ in 0..<offers {
            now += rng.pick([0, 0.01, 0.05, 0.3])
            let (rank, sub) = rng.pick(arbFuzzRanks)
            s.offer(req("k\(rng.int(40))", rank, sub: sub, ttl: rng.pick(arbFuzzTTLs)), now: now)
            maxPending = max(maxPending, s.pendingCount)
        }
        arbCheck("soak: \(offers) offers over 40 keys, queue peaked at \(maxPending) (cap 5)", maxPending <= 5)
        s.expire(now: now + 10_000)
        arbCheck("soak: drains to empty", s.active == nil && s.pendingCount == 0 && s.nextDeadline == nil)
    }
}
