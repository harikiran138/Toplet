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

// T1: DIFFERENTIAL. The new resolver must equal the old chain (ArbiterTestsOracle.swift) for every snapshot, except for an
// explicit allow-list of intentional changes. Each entry below carries its justification and a precise predicate: a
// difference is only excused when the predicate holds, and every entry must be exercised at least once (no dead entries).
//
//   B8   camera/mic privacy indicator lifted above music/timer/download (and the rest of the table). Audit 2.6 B8 and 2.7 row 3.
//        Also drops the expansion guard (the indicator no longer disappears while a battery/music expansion is visible),
//        except for the lock-screen takeover, which still blanks the notch exactly as today.
//   D1   download takes over music/timer/reminder/recording WHENEVER it runs, not only while the `.download` expansion
//        happens to hold the single expansion slot (audit B7, DECISION D1: explicit rank 8.5 instead of an accident).
//        Visible expansions of other kinds still suppress it, exactly as today.
//   B1   geometry follows the surface that actually won. Today the window/view size and the clip shape are keyed on
//        "recording is on" (and "an AirPods sneak is showing") instead of on the winner, so e.g. the charging HUD (+180) is
//        sized as the recording HUD (+132) and clipped. Audit 2.6 B1 and 2.3.
//   NEW  the two new sneak kinds (app notification, critical notification). An unmodified chain would draw them as an inline
//        HUD; the new resolver draws its own surface or ignores them. Judged against the notification-free world.

struct ArbDiffStats {
    var total = 0
    var exact = 0
    var allowed: [String: Int] = ["B8": 0, "D1": 0, "B1": 0, "NEW": 0]
    var detail: [String: Int] = [:]
    var violations = 0
    var samples: [String] = []

    mutating func merge(_ o: ArbDiffStats) {
        total += o.total; exact += o.exact; violations += o.violations
        for (k, v) in o.allowed { allowed[k, default: 0] += v }
        for (k, v) in o.detail { detail[k, default: 0] += v }
        samples += o.samples.prefix(max(0, 8 - samples.count))
    }
}

// MARK: - Independent specification of "geometry follows the winner" (written from the audit, not from the resolver)

private func specSizing(_ surface: ClosedNotchSurface, _ s: ClosedNotchSnapshot) -> ClosedNotchSizing {
    if surface == .connectivityHUD { return .connectivity }
    if surface == .batteryHUD { return .battery(s.batteryHUD) }
    if surface == .criticalNotification || surface == .appNotification {
        // wings fit the default (wide) window: never shrink to the narrower expansion-derived width
        return s.notificationCardExpanded ? .notificationCard : .tabDriven
    }
    if surface == .systemHUD && s.sneak == .airPodsMode && s.notchClosed && s.enableSneakPeek { return .airPodsInlineHUD }
    if s.notchClosed && s.enableSneakPeek && s.globalSneakStyleInline && (s.expansion == .music || s.expansion == .timer) {
        return .inlineMusicTimer
    }
    if surface == .recording { return .recording }
    return .tabDriven
}

private func specClip(_ surface: ClosedNotchSurface, _ s: ClosedNotchSnapshot) -> ClosedNotchClip {
    switch surface {
    case .connectivityHUD: return .connectivity(noConnection: s.connectivityNoConnection)
    case .recording: return s.recordingExpandedPresentation ? .recordingExpanded : .standard
    case .batteryHUD: return .battery(s.batteryHUD)
    case .criticalNotification, .appNotification: return s.notificationCardExpanded ? .notificationCard : .standard
    default: return .standard
    }
}

/// Who owns an old geometry value, and did that owner win the old chain? (B1 = the owner did not win.)
private func oldSizingOwnerLost(_ z: OldSizing, oldSurface: OldSurface, _ s: ClosedNotchSnapshot) -> Bool {
    switch z {
    case .recording: return oldSurface != .recording
    case .airPods: return oldSurface != .inlineHUD
    case .battery: return oldSurface != .battery
    default: return false
    }
}

private func oldClipOwnerLost(_ c: OldClip, oldSurface: OldSurface) -> Bool {
    switch c {
    case .recordingExpanded: return oldSurface != .recording
    case .battery: return oldSurface != .battery
    default: return false
    }
}

// MARK: - One state

func arbDifferential(_ s: ClosedNotchSnapshot, _ st: inout ArbDiffStats) {
    st.total += 1
    let new = resolveClosedNotchSurface(s)

    // New rows: judged against the notification-free world (sneak == nil), which is itself part of the sweep.
    if let k = s.sneak, k.isNotificationKind {
        var s0 = s
        s0.sneak = nil
        s0.notificationCardExpanded = false
        let base = resolveClosedNotchSurface(s0)
        let ownSurface = new.surface == .criticalNotification || new.surface == .appNotification
        let wantsKind: ClosedNotchSurface = (k == .criticalNotification) ? .criticalNotification : .appNotification
        let ok: Bool
        if ownSurface {
            ok = new.surface == wantsKind
                && new.overlay == .none
                && new.sizing == specSizing(new.surface, s) && new.clip == specClip(new.surface, s)
        } else {
            // ignored: identical to the world without the notification (geometry compared on the card-free snapshot)
            var sc = s
            sc.notificationCardExpanded = false
            let r = resolveClosedNotchSurface(sc)
            ok = r.surface == base.surface && r.sizing == base.sizing && r.clip == base.clip && r.overlay == .none
                && new == r
        }
        if ok { st.allowed["NEW", default: 0] += 1; st.detail["NEW \(k) -> \(ownSurface ? "own surface" : "ignored (as without it)")", default: 0] += 1 } else { arbViolation(&st, s, "NEW-ROWS not explained", new) }
        return
    }

    let oldS = oldChain(s)
    let oldO = oldOverlay(s)
    let oldV = oldViewSizing(s)
    let oldW = oldWindowSizing(s)
    let oldC = oldClip(s)

    let newS = asOld(new.surface)
    let surfaceDiff = newS != oldS
    let overlayDiff = asOld(new.overlay) != oldO
    let sizingDiff = asOld(new.sizing) != oldV
    // window copy: compare against the window rule (AirPods and inline are one flat 460 there)
    let windowDiff = new.sizing == .tabDriven ? oldW != .tab
        : (asOld(new.sizing).map { windowEquivalent($0) != oldW } ?? true)
    let clipDiff = asOld(new.clip) != oldC

    if !surfaceDiff && !overlayDiff && !sizingDiff && !windowDiff && !clipDiff {
        st.exact += 1
        return
    }

    if overlayDiff { arbViolation(&st, s, "overlay differs (never allowed for old kinds)", new); return }

    var claim: String? = nil
    if surfaceDiff {
        let closed = s.notchClosed
        if new.surface == .privacyIndicator && oldS != .privacy && s.privacyActive && closed && !s.hideOnClosed && s.expansion != .lockScreen {
            claim = "B8"
        } else if new.surface == .download && s.expansion == nil && s.downloadActive && closed && !s.hideOnClosed {
            switch oldS {
            case .music, .timer, .reminder, .recording: claim = "D1"
            default: break
            }
        }
        if claim == nil { arbViolation(&st, s, "surface differs without an allow-list entry", new); return }
    }

    if sizingDiff || windowDiff || clipDiff {
        // Geometry must follow the NEW winner exactly...
        let wantSize = specSizing(new.surface, s)
        let wantClip = specClip(new.surface, s)
        guard new.sizing == wantSize, new.clip == wantClip else {
            arbViolation(&st, s, "geometry does not follow the winner", new); return
        }
        // ...and a geometry difference needs a reason: the surface changed on purpose, or the old owner never won (B1).
        if claim == nil {
            let lost = (sizingDiff && oldSizingOwnerLost(oldV, oldSurface: oldS, s))
                || (windowDiff && oldSizingOwnerLost(oldW, oldSurface: oldS, s))
                || (clipDiff && oldClipOwnerLost(oldC, oldSurface: oldS))
            guard lost else { arbViolation(&st, s, "geometry differs but its old owner won", new); return }
            claim = "B1"
        }
    }
    st.allowed[claim!, default: 0] += 1
    switch claim! {
    case "B1":
        var parts: [String] = []
        if sizingDiff { parts.append("view size \(oldV)") }
        if windowDiff { parts.append("window size \(oldW)") }
        if clipDiff { parts.append("clip \(oldC)") }
        st.detail["B1 old geometry owner lost the chain: " + parts.joined(separator: ", ") + " (old winner \(oldS), new winner \(new.surface))", default: 0] += 1
    case "B8": st.detail["B8 privacy replaces old winner \(oldS)", default: 0] += 1
    case "D1": st.detail["D1 download replaces old winner \(oldS)", default: 0] += 1
    default: break
    }
}

private func arbViolation(_ st: inout ArbDiffStats, _ s: ClosedNotchSnapshot, _ why: String, _ new: ClosedNotchResolution) {
    st.violations += 1
    if st.samples.count < 8 {
        st.samples.append("\(why)\n      old: \(oldChain(s)) over=\(oldOverlay(s)) view=\(oldViewSizing(s)) win=\(oldWindowSizing(s)) clip=\(oldClip(s))\n      new: \(new.surface) over=\(new.overlay) size=\(new.sizing) clip=\(new.clip)\n      snapshot: \(s)")
    }
}

// MARK: - Enumeration

struct ArbDim {
    let n: Int
    let apply: (inout ClosedNotchSnapshot, Int) -> Void
}

private func boolDim(_ kp: WritableKeyPath<ClosedNotchSnapshot, Bool>) -> ArbDim {
    ArbDim(n: 2) { $0[keyPath: kp] = ($1 == 1) }
}

/// expansion slot: (nil, hidden), (nil, shown elsewhere), then every kind (shown, visible)
private let arbExpansionDim = ArbDim(n: 2 + ExpansionKind.allCases.count) { s, i in
    switch i {
    case 0: s.expansion = nil; s.expansionShownAnywhere = false
    case 1: s.expansion = nil; s.expansionShownAnywhere = true
    default: s.expansion = ExpansionKind.allCases[i - 2]; s.expansionShownAnywhere = true
    }
}
private let arbSneakDim = ArbDim(n: 1 + SneakKind.allCases.count) { s, i in
    s.sneak = i == 0 ? nil : SneakKind.allCases[i - 1]
    if s.sneak == .extensionActivity { s.activeSneakStyleStandard = true }
}
private func arbIntDim(_ n: Int, _ kp: WritableKeyPath<ClosedNotchSnapshot, Int>) -> ArbDim {
    ArbDim(n: n) { $0[keyPath: kp] = $1 }
}
private let arbBatteryDim = ArbDim(n: BatteryHUDSpec.allCases.count) { s, i in s.batteryHUD = BatteryHUDSpec.allCases[i] }

/// Exhaustive product over `dims` applied to `base`, pruning snapshots a real builder can never produce.
func arbEnumerate(base: ClosedNotchSnapshot, dims: [ArbDim], into st: inout ArbDiffStats) -> (raw: Int, consistent: Int) {
    var raw = 1
    for d in dims { raw *= d.n }
    var idx = [Int](repeating: 0, count: dims.count)
    var consistent = 0
    for _ in 0..<raw {
        var s = base
        for i in 0..<dims.count { dims[i].apply(&s, idx[i]) }
        if s.isConsistent {
            consistent += 1
            arbDifferential(s, &st)
        }
        var j = 0
        while j < dims.count {
            idx[j] += 1
            if idx[j] < dims[j].n { break }
            idx[j] = 0; j += 1
        }
    }
    return (raw, consistent)
}

func arbRandomSnapshot(_ rng: inout ArbRNG, density: Double) -> ClosedNotchSnapshot {
    var s = ClosedNotchSnapshot()
    s.notchClosed = rng.bool(0.8)
    s.hideOnClosed = rng.bool(density * 0.6)
    s.isLocked = rng.bool(density * 0.6)
    s.connectivityHUDVisible = rng.bool(density * 0.5)
    s.connectivityNoConnection = rng.bool()
    s.firstLaunch = rng.bool(density * 0.3)
    let e = rng.int(2 + ExpansionKind.allCases.count)
    arbExpansionDim.apply(&s, e)
    s.batteryHUD = rng.pick(BatteryHUDSpec.allCases)
    if rng.bool(0.6) { s.sneak = rng.pick(SneakKind.allCases) }
    s.inlineHUDEnabled = rng.bool(0.7)
    s.activeSneakStyleStandard = rng.bool(0.7)
    s.globalSneakStyleInline = rng.bool()
    s.enableSneakPeek = rng.bool(0.8)
    s.notificationCardExpanded = rng.bool(0.3)
    s.musicPairingEligible = rng.bool(density)
    s.capsLockActive = rng.bool(density)
    s.timerActive = rng.bool(density)
    s.reminderActive = rng.bool(density)
    s.reminderEntryPresent = rng.bool(0.7)
    s.recordingActive = rng.bool(density)
    s.recordingExpandedPresentation = rng.bool()
    s.downloadActive = rng.bool(density)
    s.localSendActive = rng.bool(density)
    s.focusActive = rng.bool(density)
    s.focusToastDismissing = rng.bool(density * 0.5)
    s.privacyActive = rng.bool(density)
    s.extensionPayloadCount = rng.int(3)
    s.extensionCoexistPayload = rng.bool(density)
    s.extensionStandaloneEnabled = rng.bool(0.85)
    s.shelfVisible = rng.bool(density)
    s.idleEligible = rng.bool(density)
    s.sneakArrivalSeq = UInt64(rng.int(100))
    if s.sneak == .extensionActivity { s.activeSneakStyleStandard = true }
    return s
}

// MARK: - The test

func arbRunDifferential() {
    arbSection("T1 differential: new resolver vs transcribed chain (ContentView.swift:1046-1164, :1508-1540, size/clip copies)")
    var total = ArbDiffStats()

    // E1 "sticky ladder": every sticky eligibility bit x expansion slot x music, normal closed notch, no sneak peek.
    do {
        var st = ArbDiffStats()
        var base = ClosedNotchSnapshot()
        base.extensionStandaloneEnabled = true
        let dims: [ArbDim] = [
            arbExpansionDim, boolDim(\.musicPairingEligible), boolDim(\.capsLockActive), boolDim(\.timerActive),
            boolDim(\.reminderActive), boolDim(\.reminderEntryPresent), boolDim(\.recordingActive), boolDim(\.downloadActive),
            boolDim(\.localSendActive), boolDim(\.focusActive), boolDim(\.focusToastDismissing), boolDim(\.privacyActive),
            boolDim(\.extensionCoexistPayload), boolDim(\.shelfVisible), boolDim(\.idleEligible), arbIntDim(2, \.extensionPayloadCount),
        ]
        let (raw, cons) = arbEnumerate(base: base, dims: dims, into: &st)
        arbCheck("E1 sticky ladder is exhaustive (raw \(raw) <= 2^20)", raw <= 1 << 20)
        arbCheck("E1: \(cons) consistent states, \(st.exact) identical, allowed \(st.allowed), violations \(st.violations)", st.violations == 0, st.samples.joined(separator: "\n"))
        total.merge(st)
    }

    // E2 "structure x sneak": screen state, first launch, connectivity, expansion, every sneak kind, HUD style flags.
    do {
        var st = ArbDiffStats()
        var base = ClosedNotchSnapshot()
        base.extensionPayloadCount = 1
        let dims: [ArbDim] = [
            boolDim(\.notchClosed), boolDim(\.hideOnClosed), boolDim(\.isLocked), boolDim(\.connectivityHUDVisible),
            boolDim(\.firstLaunch), arbExpansionDim, arbSneakDim, boolDim(\.inlineHUDEnabled), boolDim(\.activeSneakStyleStandard),
            boolDim(\.musicPairingEligible), boolDim(\.privacyActive), boolDim(\.capsLockActive), boolDim(\.timerActive),
            boolDim(\.recordingActive),
        ]
        let (raw, cons) = arbEnumerate(base: base, dims: dims, into: &st)
        arbCheck("E2 structure x sneak is exhaustive (raw \(raw) <= 2^20)", raw <= 1 << 20)
        arbCheck("E2: \(cons) consistent states, \(st.exact) identical, allowed \(st.allowed), violations \(st.violations)", st.violations == 0, st.samples.joined(separator: "\n"))
        total.merge(st)
    }

    // E3 geometry: who owns the window size and the clip.
    do {
        var st = ArbDiffStats()
        var base = ClosedNotchSnapshot()
        base.reminderActive = true
        base.reminderEntryPresent = true
        let dims: [ArbDim] = [
            boolDim(\.notchClosed), boolDim(\.hideOnClosed), boolDim(\.isLocked), boolDim(\.connectivityHUDVisible),
            arbExpansionDim, arbBatteryDim, arbSneakDim, boolDim(\.enableSneakPeek),
            boolDim(\.globalSneakStyleInline), boolDim(\.recordingActive), boolDim(\.recordingExpandedPresentation),
            boolDim(\.musicPairingEligible), boolDim(\.timerActive),
        ]
        let (raw, cons) = arbEnumerate(base: base, dims: dims, into: &st)
        arbCheck("E3 geometry is exhaustive (raw \(raw) <= 2^20)", raw <= 1 << 20)
        arbCheck("E3: \(cons) consistent states, \(st.exact) identical, allowed \(st.allowed), violations \(st.violations)", st.violations == 0, st.samples.joined(separator: "\n"))
        total.merge(st)
    }

    // E4 seeded sampling of the full space (raw product is far beyond 2^20): 1,000,000 snapshots, two densities.
    do {
        let seed: UInt64 = 0xA7011_5EED
        var rng = ArbRNG(seed: seed)
        var st = ArbDiffStats()
        var done = 0
        while done < 1_000_000 {
            let s = arbRandomSnapshot(&rng, density: done % 2 == 0 ? 0.5 : 0.15)
            if !s.isConsistent { continue }
            arbDifferential(s, &st)
            done += 1
        }
        arbCheck("E4 seeded sample (seed \(String(seed, radix: 16))): \(st.total) states, \(st.exact) identical, allowed \(st.allowed), violations \(st.violations)",
                 st.violations == 0 && st.total >= 200_000, st.samples.joined(separator: "\n"))
        total.merge(st)
    }

    let diffs = total.allowed.values.reduce(0, +)
    print("   T1 totals: \(total.total) states, \(total.exact) identical to today, \(diffs) differ only via the allow-list, \(total.violations) unexplained")
    for k in ["B8", "D1", "B1", "NEW"].sorted() { print("   allow-list \(k): \(total.allowed[k] ?? 0) states") }
    if ProcessInfo.processInfo.environment["ARBITER_DETAIL"] != nil {
        for (k, v) in total.detail.sorted(by: { $0.key < $1.key }) { print("      \(v)  \(k)") }
    }
    arbCheck("T1 no unexplained difference anywhere", total.violations == 0)
    for k in ["B8", "D1", "B1", "NEW"] {
        arbCheck("T1 allow-list entry \(k) is exercised (not a dead entry)", (total.allowed[k] ?? 0) > 0)
    }
    arbEqual("T1 allow-list has exactly 4 entries", total.allowed.count, 4)
}
