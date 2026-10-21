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

// DETERMINISTIC PRIORITY ARBITER, part 2: the sneak-peek scheduler.
// A value-type state machine with an injected clock. It owns WHICH transient item is current, for how long, and what
// happens to the others; it owns no timer and no payload semantics. The integration (one @MainActor entry point in
// DynamicIslandViewCoordinator) keeps a single sleeping Task aimed at `nextDeadline` and calls `expire(now:)` when it
// wakes. There is no DispatchQueue hop and no shared duration field: every item carries its own ttl.
//
// Rules (audit 2.7, determinism rules 1-6):
//  * every item has (token, ttl, remaining). TTL only counts down while the item is current.
//  * finish(token) / finish(dedupeKey) only affect the item that holds that token/key; a stale token is a no-op
//    (fixes B3, B4, B5: a late hide can never remove a newer item).
//  * a strictly higher rank preempts the current item; the preempted item keeps `remaining` and resumes when it is the
//    best waiting item again. Equal or lower rank waits (FIFO inside (rank, subrank, arrivalSeq)).
//  * the same dedupeKey replaces the existing item (active or waiting) and invalidates its token.
//  * the waiting queue is capped (default 5); on overflow the lowest-priority, then oldest, item is dropped.
//  * STICKY items (non-finite ttl) are never scheduled: persistent indicators live in ClosedNotchSnapshot instead.
//  * time never moves backwards; promotions happen at the logical expiry instant, so late wake-ups (or extra,
//    redundant expire() calls) cannot change the outcome.

public struct SneakPeekToken: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "#\(rawValue)" }
}

public struct SneakPeekRequest<Payload: Sendable>: Sendable {
    public var dedupeKey: String
    public var rank: NotchSurfaceRank
    public var subrank: Int
    public var ttl: TimeInterval          // seconds the item is shown; must be finite and > 0
    public var payload: Payload

    public init(dedupeKey: String, rank: NotchSurfaceRank, subrank: Int = 0, ttl: TimeInterval, payload: Payload) {
        self.dedupeKey = dedupeKey
        self.rank = rank
        self.subrank = subrank
        self.ttl = ttl
        self.payload = payload
    }
}

public struct SneakPeekItem<Payload: Sendable>: Sendable {
    public var token: SneakPeekToken
    public var dedupeKey: String
    public var key: NotchPriorityKey
    public var ttl: TimeInterval
    /// Authoritative while the item is waiting or the scheduler is paused; for the running item use
    /// `SneakPeekScheduler.remaining(now:)`.
    public var remaining: TimeInterval
    public var payload: Payload
}
extension SneakPeekItem: Equatable where Payload: Equatable {}

public enum SneakPeekRejectReason: Equatable, Sendable {
    case invalidTTL         // zero, negative or NaN
    case stickyNotScheduled // infinite ttl: persistent state belongs in ClosedNotchSnapshot, not in the scheduler
    case queueFull          // lowest-priority item of a full queue was the newcomer itself
}

public enum SneakPeekOutcome: Equatable, Sendable {
    case showing
    case replacedActive
    case queued
    case replacedQueued
    case rejected(SneakPeekRejectReason)
    case finished           // finish() removed the item that held the token/key
    case advanced           // expire()/pause()/resume() changed something
    case noop               // changed nothing (stale token, nothing due)
}

/// What a call changed. Value type, cheap to ignore.
public struct SneakPeekUpdate: Equatable, Sendable {
    public var token: SneakPeekToken? = nil          // token assigned to an offered item (nil when rejected)
    public var outcome: SneakPeekOutcome = .noop
    public var activeChanged = false
    public var expired: [SneakPeekToken] = []        // ran out of ttl
    public var dropped: [SneakPeekToken] = []        // evicted, cleared or cancelled by finish
    public var superseded: [SneakPeekToken] = []     // replaced by a newer item with the same dedupeKey
    public init() {}
}

public struct SneakPeekScheduler<Payload: Sendable>: Sendable {
    public static var maxTTL: TimeInterval { 120 }
    public static var defaultCapacity: Int { 5 }
    /// Deadlines within this many seconds of the clock count as reached (keeps float rounding from producing a
    /// running item with no time left).
    static var epsilon: TimeInterval { 1e-9 }

    public private(set) var active: SneakPeekItem<Payload>? = nil
    /// Waiting items, sorted ascending by `key` (best first).
    public private(set) var queue: [SneakPeekItem<Payload>] = []
    /// Absolute clock time at which `active` expires; nil when nothing is active or the scheduler is paused.
    public private(set) var nextDeadline: TimeInterval? = nil
    public private(set) var isPaused = false
    public private(set) var clock: TimeInterval = 0
    public let capacity: Int
    private var nextSeq: UInt64 = 1
    private var nextTokenRaw: UInt64 = 1

    public init(capacity: Int = SneakPeekScheduler.defaultCapacity) {
        self.capacity = max(0, capacity)
    }

    public var pendingCount: Int { queue.count }

    /// Remaining display time of the active item at `now` (not mutating; `now` is clamped to the scheduler's clock).
    public func remaining(now: TimeInterval) -> TimeInterval? {
        guard let a = active else { return nil }
        guard let d = nextDeadline else { return a.remaining }
        return max(0, d - max(now, clock))
    }

    // MARK: Public operations

    /// Offer a transient. Same dedupeKey replaces (new token, original arrivalSeq kept).
    @discardableResult
    public mutating func offer(_ request: SneakPeekRequest<Payload>, now: TimeInterval) -> SneakPeekUpdate {
        var u = SneakPeekUpdate()
        let before = active?.token
        advance(to: now, &u)

        guard request.ttl > 0 else { u.outcome = .rejected(.invalidTTL); return u }          // also catches NaN
        guard request.ttl.isFinite else { u.outcome = .rejected(.stickyNotScheduled); return u }
        let ttl = min(request.ttl, Self.maxTTL)
        let t = clock

        // Dedupe: the old holder of the key (active or waiting) is superseded; its arrivalSeq is inherited.
        var seq = nextSeq
        var replaced: SneakPeekOutcome? = nil
        if let a = active, a.dedupeKey == request.dedupeKey {
            u.superseded.append(a.token)
            seq = a.key.arrivalSeq
            active = nil
            nextDeadline = nil
            replaced = .replacedActive
        } else if let i = queue.firstIndex(where: { $0.dedupeKey == request.dedupeKey }) {
            u.superseded.append(queue[i].token)
            seq = queue[i].key.arrivalSeq
            queue.remove(at: i)
            replaced = .replacedQueued
        }
        nextSeq &+= 1

        let item = SneakPeekItem(token: allocateToken(), dedupeKey: request.dedupeKey,
                                 key: NotchPriorityKey(rank: request.rank, subrank: request.subrank, arrivalSeq: seq),
                                 ttl: ttl, remaining: ttl, payload: request.payload)
        u.token = item.token
        let placed = place(item, now: t, &u)
        normalize(now: t, &u)

        if case .rejected = placed {
            u.outcome = placed
        } else if let replaced {
            u.outcome = replaced
        } else {
            u.outcome = placed
        }
        // Replacing the active item with itself still counts as a visible change (payload and token changed).
        u.activeChanged = before != active?.token
        return u
    }

    /// Hide request. Only the item holding `token` is affected; anything else is a no-op.
    @discardableResult
    public mutating func finish(token: SneakPeekToken, now: TimeInterval) -> SneakPeekUpdate {
        var u = SneakPeekUpdate()
        let before = active?.token
        advance(to: now, &u)
        var removed = false
        if active?.token == token {
            u.dropped.append(token)
            active = nil
            nextDeadline = nil
            removed = true
        } else if let i = queue.firstIndex(where: { $0.token == token }) {
            u.dropped.append(token)
            queue.remove(at: i)
            removed = true
        }
        normalize(now: clock, &u)
        u.activeChanged = before != active?.token
        u.outcome = removed ? .finished : (u.expired.isEmpty ? .noop : .advanced)
        return u
    }

    /// Hide request by dedupe key (what the legacy `toggleSneakPeek(status: false, type:)` callers know). Only an item
    /// with this exact key can be removed, so a caps-lock hide can never remove a Bluetooth HUD (fixes B3).
    @discardableResult
    public mutating func finish(dedupeKey: String, now: TimeInterval) -> SneakPeekUpdate {
        if let a = active, a.dedupeKey == dedupeKey { return finish(token: a.token, now: now) }
        if let q = queue.first(where: { $0.dedupeKey == dedupeKey }) { return finish(token: q.token, now: now) }
        var u = SneakPeekUpdate()
        let before = active?.token
        advance(to: now, &u)
        normalize(now: clock, &u)
        u.activeChanged = before != active?.token
        u.outcome = u.expired.isEmpty ? .noop : .advanced
        return u
    }

    /// Advance the clock. Call when the deadline Task wakes, and freely at any other time (idempotent, composable).
    @discardableResult
    public mutating func expire(now: TimeInterval) -> SneakPeekUpdate {
        var u = SneakPeekUpdate()
        let before = active?.token
        advance(to: now, &u)
        normalize(now: clock, &u)
        u.activeChanged = before != active?.token
        u.outcome = (u.expired.isEmpty && !u.activeChanged) ? .noop : .advanced
        return u
    }

    /// Freeze the countdown (hover over the notch). The active item keeps its remaining time.
    @discardableResult
    public mutating func pause(now: TimeInterval) -> SneakPeekUpdate {
        var u = SneakPeekUpdate()
        let before = active?.token
        advance(to: now, &u)
        if !isPaused {
            isPaused = true
            if var a = active, let d = nextDeadline {
                a.remaining = max(0, d - clock)
                active = a
                nextDeadline = nil
            }
        }
        normalize(now: clock, &u)
        u.activeChanged = before != active?.token
        u.outcome = (u.expired.isEmpty && !u.activeChanged) ? .noop : .advanced
        return u
    }

    /// Resume after `pause`.
    @discardableResult
    public mutating func resume(now: TimeInterval) -> SneakPeekUpdate {
        var u = SneakPeekUpdate()
        let before = active?.token
        advance(to: now, &u)
        if isPaused {
            isPaused = false
            if let a = active { nextDeadline = clock + a.remaining }
        }
        normalize(now: clock, &u)
        u.activeChanged = before != active?.token
        u.outcome = (u.expired.isEmpty && !u.activeChanged) ? .noop : .advanced
        return u
    }

    /// Drop everything (lock screen, display change).
    @discardableResult
    public mutating func clearAll(now: TimeInterval) -> SneakPeekUpdate {
        var u = SneakPeekUpdate()
        let before = active?.token
        advance(to: now, &u)
        if let a = active { u.dropped.append(a.token) }
        u.dropped.append(contentsOf: queue.map(\.token))
        active = nil
        nextDeadline = nil
        queue.removeAll(keepingCapacity: true)
        u.activeChanged = before != nil
        u.outcome = u.dropped.isEmpty ? .noop : .finished
        return u
    }

    // MARK: Internals

    private mutating func allocateToken() -> SneakPeekToken {
        defer { nextTokenRaw &+= 1 }
        return SneakPeekToken(nextTokenRaw)
    }

    /// Move the clock to `now` (never backwards), expiring and promoting at each logical expiry instant.
    private mutating func advance(to now: TimeInterval, _ u: inout SneakPeekUpdate) {
        guard now.isFinite else { return }
        let target = max(now, clock)
        while !isPaused, let d = nextDeadline, d <= target + Self.epsilon {
            if let a = active { u.expired.append(a.token) }
            active = nil
            nextDeadline = nil
            promote(at: d)
        }
        clock = target
    }

    /// Make the best waiting item active, starting at logical time `t`.
    private mutating func promote(at t: TimeInterval) {
        guard active == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        active = item
        nextDeadline = isPaused ? nil : t + item.remaining
    }

    /// Establish the invariant: the active item is never worse (by rank) than the best waiting one.
    private mutating func normalize(now t: TimeInterval, _ u: inout SneakPeekUpdate) {
        if active == nil { promote(at: t) }
        while let a = active, let best = queue.first, best.key.rank.position < a.key.rank.position {
            queue.removeFirst()
            preempt(by: best, now: t, &u)
        }
    }

    /// Place a fresh item: show it, preempt, or queue it.
    private mutating func place(_ item: SneakPeekItem<Payload>, now t: TimeInterval, _ u: inout SneakPeekUpdate) -> SneakPeekOutcome {
        guard let a = active else {
            active = item
            nextDeadline = isPaused ? nil : t + item.remaining
            return .showing
        }
        if item.key.rank.position < a.key.rank.position {
            preempt(by: item, now: t, &u)
            return .showing
        }
        return enqueue(item, &u) ? .queued : .rejected(.queueFull)
    }

    /// `item` becomes active; the current item goes back to the queue with its remaining time (or ends if none is left).
    private mutating func preempt(by item: SneakPeekItem<Payload>, now t: TimeInterval, _ u: inout SneakPeekUpdate) {
        if var old = active {
            let rem = nextDeadline.map { max(0, $0 - t) } ?? old.remaining
            if rem > 0 {
                old.remaining = rem
                _ = enqueue(old, &u)
            } else {
                u.expired.append(old.token)
            }
        }
        active = item
        nextDeadline = isPaused ? nil : t + item.remaining
    }

    /// Sorted insert with the cap. Returns false when the newcomer itself was the eviction victim.
    private mutating func enqueue(_ item: SneakPeekItem<Payload>, _ u: inout SneakPeekUpdate) -> Bool {
        let idx = queue.firstIndex(where: { item.key < $0.key }) ?? queue.count
        queue.insert(item, at: idx)
        guard queue.count > capacity else { return true }
        // Victim: lowest priority (largest position, then largest subrank), oldest first (smallest arrivalSeq).
        var v = 0
        for i in 1..<queue.count {
            let a = queue[i].key, b = queue[v].key
            if a.rank.position != b.rank.position {
                if a.rank.position > b.rank.position { v = i }
            } else if a.subrank != b.subrank {
                if a.subrank > b.subrank { v = i }
            } else if a.arrivalSeq < b.arrivalSeq {
                v = i
            }
        }
        let victim = queue.remove(at: v)
        u.dropped.append(victim.token)
        return victim.token != item.token
    }
}

extension SneakPeekScheduler: Equatable where Payload: Equatable {}
