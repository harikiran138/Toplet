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

// Resolver unit tests: the table, the explicit decisions (B8, D1, D2, B1), the new rows, geometry, overlay, purity,
// and the performance budget. The differential sweep lives in ArbiterTestsDifferential.swift.

private func snap(_ f: (inout ClosedNotchSnapshot) -> Void = { _ in }) -> ClosedNotchSnapshot {
    var s = ClosedNotchSnapshot()
    f(&s)
    return s
}

private func win(_ s: ClosedNotchSnapshot, _ p: NotchPriorityPolicy = .standard) -> ClosedNotchSurface {
    resolveClosedNotchSurface(s, policy: p).surface
}

private let arbAllSurfaces: [ClosedNotchSurface] = [
    .connectivityHUD, .hello, .privacyIndicator, .batteryHUD, .criticalNotification, .systemHUD, .appNotification,
    .capsLockIndicator, .download, .music(badge: nil), .timer, .reminder, .recording, .localSend, .focus,
    .extensionStandalone, .shelf, .idle, .header, .empty,
]

func arbRunResolverTests() {
    arbSection("Table integrity")
    for policy in [NotchPriorityPolicy(), NotchPriorityPolicy(downloadTakesOver: false), NotchPriorityPolicy(privacyPreemptsTransientHUDs: false),
                   NotchPriorityPolicy(downloadTakesOver: false, privacyPreemptsTransientHUDs: false)] {
        let positions = arbAllSurfaces.map { policy.rank(of: $0).position }
        arbEqual("positions are unique (\(policy))", Set(positions).count, positions.count)
    }
    do {
        let std = NotchPriorityPolicy.standard
        var monotone = true
        for a in arbAllSurfaces {
            for b in arbAllSurfaces {
                let ra = std.rank(of: a), rb = std.rank(of: b)
                if ra.rankClass < rb.rankClass && !(ra.position < rb.position) { monotone = false }
            }
        }
        arbCheck("rank classes are ordered STRUCTURAL < SAFETY < TRANSIENT < STICKY < AMBIENT (default policy)", monotone)
        arbEqual("D1 default: download is rank 8.5", std.rank(of: .download).position, 85)
        arbEqual("D1 default: constant is true", NotchPriorityPolicy.defaultDownloadTakesOver, true)
        arbEqual("music is rank 9", std.rank(of: .music(badge: nil)).position, 90)
        arbEqual("privacy is rank 3 (SAFETY)", std.rank(of: .privacyIndicator), NotchSurfaceRank.privacy)
        arbEqual("critical is rank 5, app notification rank 7",
                 [std.rank(of: .criticalNotification).position, std.rank(of: .appNotification).position], [50, 70])
        arbCheck("total order key is (rank, subrank, arrivalSeq)",
                 NotchPriorityKey(rank: .systemHUD, subrank: 0, arrivalSeq: 9) < NotchPriorityKey(rank: .systemHUD, subrank: 1, arrivalSeq: 1)
                 && NotchPriorityKey(rank: .systemHUD, subrank: 1, arrivalSeq: 1) < NotchPriorityKey(rank: .systemHUD, subrank: 1, arrivalSeq: 2)
                 && NotchPriorityKey(rank: .battery, subrank: 9, arrivalSeq: 9) < NotchPriorityKey(rank: .systemHUD, subrank: 0, arrivalSeq: 0))
    }

    arbSection("Ladder (default policy)")
    do {
        var s = snap { $0.connectivityHUDVisible = true; $0.firstLaunch = true; $0.privacyActive = true }
        arbEqual("connectivity beats hello and privacy", win(s), .connectivityHUD)
        s.connectivityHUDVisible = false
        arbEqual("hello beats privacy", win(s), .hello)
        s.firstLaunch = false
        arbEqual("privacy wins when alone", win(s), .privacyIndicator)
        s.privacyActive = false
        arbEqual("nothing active: empty", win(s), .empty)
        arbEqual("open notch: header", win(snap { $0.notchClosed = false }), .header)
    }
    do {
        // Everything sticky is eligible; peel the winner each time.
        var s = snap {
            $0.capsLockActive = true; $0.musicPairingEligible = true; $0.timerActive = true; $0.reminderActive = true
            $0.reminderEntryPresent = true; $0.recordingActive = true; $0.downloadActive = true; $0.localSendActive = true
            $0.focusActive = true; $0.extensionPayloadCount = 1; $0.shelfVisible = true; $0.idleEligible = true
        }
        arbEqual("caps lock indicator (rank 8) first", win(s), .capsLockIndicator)
        s.capsLockActive = false
        arbEqual("download (rank 8.5, D1) over music when running", win(s), .download)
        s.downloadActive = false
        arbEqual("music (rank 9) next, badge timer", win(s), .music(badge: .timer))
        s.musicPairingEligible = false
        arbEqual("timer (rank 10)", win(s), .timer)
        s.timerActive = false
        arbEqual("reminder (rank 11)", win(s), .reminder)
        s.reminderActive = false
        arbEqual("recording (rank 12)", win(s), .recording)
        s.recordingActive = false
        arbEqual("localSend (rank 14)", win(s), .localSend)
        s.localSendActive = false
        arbEqual("focus (rank 15)", win(s), .focus)
        s.focusActive = false
        arbEqual("extension standalone (rank 16)", win(s), .extensionStandalone)
        s.extensionPayloadCount = 0
        arbEqual("shelf (rank 17)", win(s), .shelf)
        s.shelfVisible = false
        arbEqual("idle (rank 18)", win(s), .idle)
        s.idleEligible = false
        arbEqual("then empty", win(s), .empty)
    }

    arbSection("Music badge order (ContentView.swift:1508-1540)")
    do {
        var s = snap {
            $0.musicPairingEligible = true; $0.timerActive = true; $0.reminderActive = true; $0.reminderEntryPresent = true
            $0.recordingActive = true; $0.focusActive = true; $0.capsLockActive = true; $0.extensionPayloadCount = 1
            $0.extensionCoexistPayload = true; $0.shelfVisible = true
        }
        // caps lock indicator outranks music, so peel it from the surface question: ask the badge through a snapshot
        // where the persistent indicator is not a candidate (locked screens still pair music? no: use hideOnClosed-free path)
        s.capsLockActive = false
        let order: [(String, (inout ClosedNotchSnapshot) -> Void, MusicBadge?)] = [
            ("timer", { $0.timerActive = false }, .timer),
            ("reminder", { $0.reminderActive = false }, .reminder),
            ("recording", { $0.recordingActive = false }, .recording),
            ("focus", { $0.focusActive = false }, .focus),
            ("extension", { $0.extensionCoexistPayload = false }, .extensionPayload),
            ("shelf", { $0.shelfVisible = false }, .shelf),
            ("none", { _ in }, nil),
        ]
        for (name, clear, badge) in order {
            arbEqual("badge \(name)", win(s), .music(badge: badge))
            clear(&s)
        }
        var c = snap { $0.musicPairingEligible = true; $0.capsLockActive = true }
        arbEqual("caps lock indicator outranks music; the badge is moot", win(c), .capsLockIndicator)
        c.capsLockActive = false
        arbEqual("a recording with music paired is a badge, not a surface", win(snap { $0.musicPairingEligible = true; $0.recordingActive = true }), .music(badge: .recording))
        arbEqual("extension badge excludes that payload from the standalone row",
                 win(snap { $0.musicPairingEligible = true; $0.extensionPayloadCount = 1; $0.extensionCoexistPayload = true }), .music(badge: .extensionPayload))
    }

    arbSection("B8: privacy indicator lifted (audit 2.6 B8)")
    do {
        let on = { (f: @escaping (inout ClosedNotchSnapshot) -> Void) in snap { $0.privacyActive = true; f(&$0) } }
        arbEqual("music playing, default settings: privacy visible (was hidden)", win(on { $0.musicPairingEligible = true }), .privacyIndicator)
        arbEqual("timer running", win(on { $0.timerActive = true }), .privacyIndicator)
        arbEqual("download expansion held", win(on { $0.expansion = .download; $0.expansionShownAnywhere = true; $0.downloadActive = true }), .privacyIndicator)
        arbEqual("download running, slot empty", win(on { $0.downloadActive = true }), .privacyIndicator)
        arbEqual("recording + caps lock + music", win(on { $0.recordingActive = true; $0.capsLockActive = true; $0.musicPairingEligible = true }), .privacyIndicator)
        arbEqual("a music expansion does not hide it", win(on { $0.expansion = .music; $0.expansionShownAnywhere = true; $0.musicPairingEligible = true }), .privacyIndicator)
        arbEqual("D2 default: beats the charging HUD", win(on { $0.expansion = .battery; $0.expansionShownAnywhere = true }), .privacyIndicator)
        arbEqual("D2 default: beats a volume HUD", win(on { $0.sneak = .volume }), .privacyIndicator)
        arbEqual("hidden when the notch is open", win(on { $0.notchClosed = false }), .header)
        arbEqual("hidden in fullscreen (hideOnClosed)", win(on { $0.hideOnClosed = true }), .empty)
        arbEqual("the lock-screen takeover still blanks the notch (as today)", win(on { $0.expansion = .lockScreen; $0.expansionShownAnywhere = true }), .empty)
        arbEqual("connectivity and hello still win", [win(on { $0.connectivityHUDVisible = true }), win(on { $0.firstLaunch = true })], [.connectivityHUD, .hello])
    }
    do {
        let d2off = NotchPriorityPolicy(privacyPreemptsTransientHUDs: false)
        let on = { (f: @escaping (inout ClosedNotchSnapshot) -> Void) in snap { $0.privacyActive = true; f(&$0) } }
        arbEqual("D2 off: charging HUD still wins", win(on { $0.expansion = .battery; $0.expansionShownAnywhere = true }, d2off), .batteryHUD)
        arbEqual("D2 off: volume HUD still wins", win(on { $0.sneak = .volume }, d2off), .systemHUD)
        arbEqual("D2 off: app notification wins", win(on { $0.sneak = .notification }, d2off), .appNotification)
        arbEqual("D2 off: still above caps lock, music, timer, download",
                 [win(on { $0.capsLockActive = true }, d2off), win(on { $0.musicPairingEligible = true }, d2off),
                  win(on { $0.timerActive = true }, d2off), win(on { $0.downloadActive = true }, d2off)],
                 [.privacyIndicator, .privacyIndicator, .privacyIndicator, .privacyIndicator])
    }

    arbSection("D1: download takes over while it runs (audit B7)")
    do {
        let all = { (f: @escaping (inout ClosedNotchSnapshot) -> Void) in
            snap { $0.downloadActive = true; $0.timerActive = true; $0.reminderActive = true; $0.recordingActive = true
                   $0.musicPairingEligible = true; f(&$0) }
        }
        arbEqual("slot empty: download over music, timer, reminder, recording", win(all { _ in }), .download)
        arbEqual("slot holds .download: same", win(all { $0.expansion = .download; $0.expansionShownAnywhere = true }), .download)
        arbEqual("slot holds a music expansion: music keeps the notch (guard preserved)",
                 win(all { $0.expansion = .music; $0.expansionShownAnywhere = true }), .music(badge: .timer))
        arbEqual("slot holds a recording expansion with no music paired: recording",
                 win(all { $0.expansion = .recording; $0.expansionShownAnywhere = true; $0.musicPairingEligible = false; $0.timerActive = false; $0.reminderActive = false }), .recording)
        arbEqual("caps lock indicator (rank 8) still outranks download", win(all { $0.capsLockActive = true }), .capsLockIndicator)
        arbEqual("a volume HUD still outranks download", win(all { $0.sneak = .volume }), .systemHUD)
        let d1off = NotchPriorityPolicy(downloadTakesOver: false)
        arbEqual("D1 off: music wins over download", win(all { _ in }, d1off), .music(badge: .timer))
        arbEqual("D1 off: timer wins over download", win(all { $0.musicPairingEligible = false }, d1off), .timer)
        arbEqual("D1 off: reminder wins", win(all { $0.musicPairingEligible = false; $0.timerActive = false }, d1off), .reminder)
        arbEqual("D1 off: recording wins", win(all { $0.musicPairingEligible = false; $0.timerActive = false; $0.reminderActive = false }, d1off), .recording)
        arbEqual("D1 off: download beats localSend",
                 win(snap { $0.downloadActive = true; $0.localSendActive = true }, d1off), .download)
        arbEqual("D1 off: a .download expansion no longer suppresses the timer",
                 win(snap { $0.expansion = .download; $0.expansionShownAnywhere = true; $0.downloadActive = true; $0.timerActive = true }, d1off), .timer)
        arbEqual("D1 off: positions: download is 12.5", d1off.rank(of: .download).position, 125)
    }

    arbSection("New rows: critical (5) and app notification (7)")
    do {
        let crit = { (f: @escaping (inout ClosedNotchSnapshot) -> Void) in snap { $0.sneak = .criticalNotification; f(&$0) } }
        let app = { (f: @escaping (inout ClosedNotchSnapshot) -> Void) in snap { $0.sneak = .notification; f(&$0) } }
        arbEqual("critical alone", win(crit { _ in }), .criticalNotification)
        arbEqual("app notification alone", win(app { _ in }), .appNotification)
        let busy: (inout ClosedNotchSnapshot) -> Void = {
            $0.capsLockActive = true; $0.musicPairingEligible = true; $0.timerActive = true; $0.downloadActive = true
            $0.recordingActive = true; $0.focusActive = true; $0.shelfVisible = true; $0.idleEligible = true
        }
        arbEqual("critical beats every sticky row", win(crit(busy)), .criticalNotification)
        arbEqual("app notification beats every sticky row (it is rank 7)", win(app(busy)), .appNotification)
        arbEqual("battery HUD (4) beats critical (5)", win(crit { $0.expansion = .battery; $0.expansionShownAnywhere = true }), .batteryHUD)
        arbEqual("battery HUD beats app notification", win(app { $0.expansion = .battery; $0.expansionShownAnywhere = true }), .batteryHUD)
        arbEqual("privacy (3) beats critical", win(crit { $0.privacyActive = true }), .privacyIndicator)
        arbEqual("hello and connectivity beat critical", [win(crit { $0.firstLaunch = true }), win(crit { $0.connectivityHUDVisible = true })], [.hello, .connectivityHUD])
        arbEqual("not drawn when the notch is open", win(app { $0.notchClosed = false }), .header)
        arbEqual("not drawn in fullscreen (hideOnClosed)", win(crit { $0.hideOnClosed = true }), .empty)
        arbEqual("not drawn on the lock screen", win(app { $0.isLocked = true }), .empty)
        arbEqual("a download expansion does not hide a notification", win(app { $0.expansion = .download; $0.expansionShownAnywhere = true; $0.downloadActive = true }), .appNotification)
        arbEqual("no under-notch overlay for notifications", resolveClosedNotchSurface(app { $0.inlineHUDEnabled = false }).overlay, .none)
        arbEqual("compact notification: no window growth", resolveClosedNotchSurface(app { _ in }).growsWindow, false)
        let card = resolveClosedNotchSurface(app { $0.notificationCardExpanded = true })
        arbCheck("expanded card: window grows downward with its own clip", card.sizing == .notificationCard && card.clip == .notificationCard && card.growsWindow && card.growsWindowHeight)
        arbEqual("sneak classifier: critical -> rank 5 sub 0", NotchSneakClassifier.classify(kind: .reminder, priority: .critical).rank, NotchSurfaceRank.criticalAlert)
        arbEqual("sneak classifier: bluetooth is subrank 0, volume 1",
                 [NotchSneakClassifier.classify(kind: .bluetooth).subrank, NotchSneakClassifier.classify(kind: .volume).subrank], [0, 1])
    }
    do {
        // Property: the notification surface wins exactly when nothing outranks it. 300k seeded snapshots.
        var rng = ArbRNG(seed: 0x07_1F1CA)
        var bad = 0, n = 0
        for _ in 0..<300_000 {
            var s = arbRandomSnapshot(&rng, density: rng.bool() ? 0.5 : 0.15)
            guard s.isConsistent else { continue }
            s.sneak = rng.bool() ? .criticalNotification : .notification
            n += 1
            let r = resolveClosedNotchSurface(s)
            let eligible = s.notchClosed && !s.hideOnClosed && !s.isLocked && s.expansion != .lockScreen
            let outranked = s.connectivityHUDVisible || s.firstLaunch || (s.privacyActive && s.notchClosed && !s.hideOnClosed && s.expansion != .lockScreen)
                || (s.expansion == .battery && s.notchClosed)
            let own: ClosedNotchSurface = s.sneak == .criticalNotification ? .criticalNotification : .appNotification
            let expectOwn = eligible && !outranked
            if (r.surface == own) != expectOwn { bad += 1 }
            if r.surface == .criticalNotification && s.sneak != .criticalNotification { bad += 1 }
            if r.surface == .appNotification && s.sneak != .notification { bad += 1 }
        }
        arbCheck("notification surface wins exactly when eligible and not outranked (\(n) seeded snapshots)", bad == 0, "bad=\(bad)")
    }

    arbSection("B1: size and clip follow the winner (audit 2.6 B1, 2.3)")
    do {
        let rec = { (f: @escaping (inout ClosedNotchSnapshot) -> Void) in snap { $0.recordingActive = true; f(&$0) } }
        let bat = resolveClosedNotchSurface(rec { $0.expansion = .battery; $0.expansionShownAnywhere = true })
        arbCheck("recording + charging HUD: battery size (+180), battery clip (old: recording +132, clipped)",
                 bat.surface == .batteryHUD && bat.sizing == .battery(.compact) && bat.clip == .battery(.compact))
        let bstd = resolveClosedNotchSurface(rec { $0.expansion = .battery; $0.expansionShownAnywhere = true; $0.batteryHUD = .standardLow })
        arbCheck("recording + low-battery standard HUD: grows +75 high", bstd.sizing == .battery(.standardLow) && bstd.growsWindowHeight)
        let tim = resolveClosedNotchSurface(rec { $0.timerActive = true })
        arbCheck("recording on but the timer wins: default (wide) size, not the narrow recording size",
                 tim.surface == .timer && tim.sizing == .tabDriven && tim.clip == .standard)
        let r = resolveClosedNotchSurface(rec { _ in })
        arbCheck("recording alone: recording size", r.surface == .recording && r.sizing == .recording && r.clip == .standard)
        let rex = resolveClosedNotchSurface(rec { $0.recordingExpandedPresentation = true })
        arbCheck("recording expanded on hover: recording clip", rex.clip == .recordingExpanded && rex.sizing == .recording)
        let rmusic = resolveClosedNotchSurface(rec { $0.musicPairingEligible = true })
        arbCheck("recording paired as a music badge: no recording size", rmusic.surface == .music(badge: .recording) && rmusic.sizing == .tabDriven)
        let air = resolveClosedNotchSurface(snap { $0.sneak = .airPodsMode })
        arbCheck("AirPods listening mode HUD: its own width", air.surface == .systemHUD && air.sizing == .airPodsInlineHUD && air.growsWindow)
        let airBat = resolveClosedNotchSurface(snap { $0.sneak = .airPodsMode; $0.expansion = .battery; $0.expansionShownAnywhere = true })
        arbCheck("AirPods HUD showing while the charging HUD wins: battery size (old: AirPods width)", airBat.surface == .batteryHUD && airBat.sizing == .battery(.compact))
        let airOff = resolveClosedNotchSurface(snap { $0.sneak = .airPodsMode; $0.enableSneakPeek = false })
        arbEqual("AirPods HUD with sneak peeks disabled: default size (as today)", airOff.sizing, .tabDriven)
        let inl = resolveClosedNotchSurface(snap { $0.expansion = .music; $0.expansionShownAnywhere = true; $0.globalSneakStyleInline = true; $0.musicPairingEligible = true })
        arbCheck("inline music expansion: 460-wide", inl.surface == .music(badge: nil) && inl.sizing == .inlineMusicTimer)
        let con = resolveClosedNotchSurface(snap { $0.connectivityHUDVisible = true; $0.connectivityNoConnection = true; $0.recordingActive = true })
        arbCheck("connectivity: its own size and clip", con.sizing == .connectivity && con.clip == .connectivity(noConnection: true))
        arbCheck("growsWindow is false for default-size surfaces", !resolveClosedNotchSurface(snap { $0.idleEligible = true }).growsWindow)
    }

    arbSection("Overlay (ContentView.swift:1166-1249)")
    do {
        func ov(_ f: (inout ClosedNotchSnapshot) -> Void) -> SneakOverlay { resolveClosedNotchSurface(snap(f)).overlay }
        arbEqual("volume, inline HUD off: SystemEventIndicator", ov { $0.sneak = .volume; $0.inlineHUDEnabled = false }, .systemEventIndicator)
        arbEqual("volume, inline HUD on: no overlay", ov { $0.sneak = .volume }, .none)
        arbEqual("volume while the notch is open, inline off: none", ov { $0.sneak = .volume; $0.inlineHUDEnabled = false; $0.notchClosed = false }, .none)
        arbEqual("AirPods mode never uses the system indicator", ov { $0.sneak = .airPodsMode; $0.inlineHUDEnabled = false }, .none)
        arbEqual("music sneak, standard style", ov { $0.sneak = .music }, .musicMarquee)
        arbEqual("music sneak, inline style: none", ov { $0.sneak = .music; $0.activeSneakStyleStandard = false }, .none)
        arbEqual("timer sneak", ov { $0.sneak = .timer }, .timerMarquee)
        arbEqual("reminder sneak needs an entry", [ov { $0.sneak = .reminder }, ov { $0.sneak = .reminder; $0.reminderEntryPresent = true }], [.none, .reminderMarquee])
        arbEqual("extension sneak", ov { $0.sneak = .extensionActivity }, .extensionMarquee)
        arbEqual("caps lock sneak has no overlay", ov { $0.sneak = .capsLock; $0.inlineHUDEnabled = false }, .none)
        arbEqual("hideOnClosed hides marquees", ov { $0.sneak = .timer; $0.hideOnClosed = true }, .none)
        arbCheck("type lists live in one place: only these kinds render as the inline HUD",
                 Set(SneakKind.allCases.filter { $0.rendersAsInlineHUD }) == [.volume, .brightness, .backlight, .bluetooth, .airPodsMode, .capsLock, .other])
    }

    arbSection("Purity and policy plumbing")
    do {
        var rng = ArbRNG(seed: 0x9091)
        var impure = 0, d1Bad = 0, d2Bad = 0, n = 0
        let d1off = NotchPriorityPolicy(downloadTakesOver: false)
        let d2off = NotchPriorityPolicy(privacyPreemptsTransientHUDs: false)
        for _ in 0..<300_000 {
            let s = arbRandomSnapshot(&rng, density: rng.bool() ? 0.5 : 0.15)
            guard s.isConsistent else { continue }
            n += 1
            if resolveClosedNotchSurface(s) != resolveClosedNotchSurface(s) { impure += 1 }
            // D1 off: a download expansion behaves like an empty slot.
            if s.expansion == .download {
                var t = s; t.expansion = nil; t.expansionShownAnywhere = false
                if resolveClosedNotchSurface(s, policy: d1off) != resolveClosedNotchSurface(t, policy: d1off) { d1Bad += 1 }
            }
            // D2: privacy eligible => with D2 on only connectivity/hello can beat it; with D2 off only the transient rows can.
            if s.privacyActive && s.notchClosed && !s.hideOnClosed && s.expansion != .lockScreen {
                let on = resolveClosedNotchSurface(s).surface
                if !(on == .connectivityHUD || on == .hello || on == .privacyIndicator) { d2Bad += 1 }
                let off = resolveClosedNotchSurface(s, policy: d2off).surface
                let allowed: [ClosedNotchSurface] = [.connectivityHUD, .hello, .batteryHUD, .criticalNotification, .systemHUD, .appNotification, .privacyIndicator]
                if !allowed.contains(off) { d2Bad += 1 }
            }
        }
        arbEqual("resolve is a pure function (\(n) snapshots)", impure, 0)
        arbEqual("D1 off is exactly 'download expansion ignored'", d1Bad, 0)
        arbEqual("D2 on/off: only the documented rows may outrank privacy", d2Bad, 0)
    }

    arbSection("Performance")
    do {
        var rng = ArbRNG(seed: 0xFEED)
        var pool: [ClosedNotchSnapshot] = []
        while pool.count < 4096 {
            let s = arbRandomSnapshot(&rng, density: pool.count % 2 == 0 ? 0.5 : 0.15)
            if s.isConsistent { pool.append(s) }
        }
        var sink = 0
        for i in 0..<20_000 { sink &+= resolveClosedNotchSurface(pool[i & 4095]).key.rank.position }   // warm-up
        let iterations = 2_000_000
        let t0 = arbNowNanos()
        for i in 0..<iterations { sink &+= resolveClosedNotchSurface(pool[i & 4095]).key.rank.position }
        let t1 = arbNowNanos()
        let avg = Double(t1 - t0) / Double(iterations)
        print("   resolve() average: \(String(format: "%.0f", avg)) ns over \(iterations) calls (sink \(sink))")
        arbCheck("resolve() averages under 5 microseconds (\(String(format: "%.0f", avg)) ns)", avg < 5_000)
    }
}
