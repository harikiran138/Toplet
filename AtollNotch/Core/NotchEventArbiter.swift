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

// DETERMINISTIC PRIORITY ARBITER, part 1: the closed-notch surface resolver.
// See docs/NOTCH-PRIORITY.md (spec, call-site diff plan) and docs/NOTIFICATIONS-IDLE-AUDIT.md section 2 (table 2.7).
//
// ONE pure function, resolveClosedNotchSurface(_:), answers "what does the closed notch draw" for ContentView's chain,
// "how big must the view and the window be" for dynamicNotchSize / calculateRequiredNotchSize, and "which clip shape"
// for resolvedClipShape. Foundation only: no AppKit, no SwiftUI, no Defaults, no singletons. The caller flattens its
// live state into a ClosedNotchSnapshot (feature toggles are folded into the booleans) and consumes the result.

// MARK: - Rank

/// Rank classes of audit 2.7. Lower raw value = more important.
public enum NotchRankClass: Int, Comparable, Sendable, CaseIterable {
    case structural = 0   // screen state, never preempted
    case safety           // privacy / critical: preempts media
    case transient        // timed, preempts and resumes
    case sticky           // lives while its condition holds
    case ambient          // decorative

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A position in the audit table. `position` is the table rank x 10 so that "rank 8.5" (download, D1) is representable.
/// Smaller position wins. Equality compares class and position; ordering compares position only (positions are unique
/// per surface, see `NotchPriorityPolicy.rank(of:)`).
public struct NotchSurfaceRank: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let position: Int
    public let rankClass: NotchRankClass

    public init(position: Int, rankClass: NotchRankClass) {
        self.position = position
        self.rankClass = rankClass
    }

    public static func < (a: Self, b: Self) -> Bool { a.position < b.position }
    public var description: String { "rank \(Double(position) / 10)(\(rankClass))" }

    // The table, one constant per row (audit 2.7).
    public static let connectivity      = NotchSurfaceRank(position: 10,  rankClass: .structural)
    public static let hello             = NotchSurfaceRank(position: 20,  rankClass: .structural)
    public static let privacy           = NotchSurfaceRank(position: 30,  rankClass: .safety)
    public static let battery           = NotchSurfaceRank(position: 40,  rankClass: .transient)
    public static let criticalAlert     = NotchSurfaceRank(position: 50,  rankClass: .transient)
    public static let systemHUD         = NotchSurfaceRank(position: 60,  rankClass: .transient)
    public static let appNotification   = NotchSurfaceRank(position: 70,  rankClass: .transient)
    public static let capsLock          = NotchSurfaceRank(position: 80,  rankClass: .sticky)
    public static let music             = NotchSurfaceRank(position: 90,  rankClass: .sticky)
    public static let timer             = NotchSurfaceRank(position: 100, rankClass: .sticky)
    public static let reminder          = NotchSurfaceRank(position: 110, rankClass: .sticky)
    public static let recording         = NotchSurfaceRank(position: 120, rankClass: .sticky)
    public static let localSend         = NotchSurfaceRank(position: 140, rankClass: .sticky)
    public static let focus             = NotchSurfaceRank(position: 150, rankClass: .sticky)
    public static let extensionActivity = NotchSurfaceRank(position: 160, rankClass: .sticky)
    public static let shelf             = NotchSurfaceRank(position: 170, rankClass: .ambient)
    public static let idle              = NotchSurfaceRank(position: 180, rankClass: .ambient)
    public static let header            = NotchSurfaceRank(position: 190, rankClass: .ambient)
    public static let empty             = NotchSurfaceRank(position: 200, rankClass: .ambient)
}

/// Total order key: (rank, subrank, arrivalSeq). `arrivalSeq` is a counter incremented when an event is accepted;
/// wall-clock time and dispatch-hop order never break ties.
public struct NotchPriorityKey: Comparable, Hashable, Sendable {
    public var rank: NotchSurfaceRank
    public var subrank: Int
    public var arrivalSeq: UInt64

    public init(rank: NotchSurfaceRank, subrank: Int = 0, arrivalSeq: UInt64 = 0) {
        self.rank = rank
        self.subrank = subrank
        self.arrivalSeq = arrivalSeq
    }

    public static func < (a: Self, b: Self) -> Bool {
        if a.rank.position != b.rank.position { return a.rank.position < b.rank.position }
        if a.subrank != b.subrank { return a.subrank < b.subrank }
        return a.arrivalSeq < b.arrivalSeq
    }
}

// MARK: - Policy (the DECISION constants)

public struct NotchPriorityPolicy: Equatable, Sendable {
    /// DECISION D1 (audit 2.7 row 13, bug B7). TRUE keeps today's observable behaviour: while a download runs it takes the
    /// notch over music, timer, reminder and recording, but as an explicit rank 8.5 instead of an accident of expansion
    /// guards. FALSE demotes it to just below recording (the order the chain is written in); a visible `.download`
    /// expansion then no longer suppresses the other rows. Change this ONE constant to flip the decision.
    public static let defaultDownloadTakesOver = true

    /// DECISION D2 (audit 2.7 row 3 plus determinism rule 6). TRUE (the audit table): the camera/mic indicator is rank 3,
    /// above the battery HUD and the system HUDs, so a volume key press is NOT drawn inline while the camera is on.
    /// FALSE: the indicator is lifted above music/timer/download (bug B8) but stays below the transient HUDs.
    public static let defaultPrivacyPreemptsTransientHUDs = true

    public var downloadTakesOver: Bool
    public var privacyPreemptsTransientHUDs: Bool

    public init(downloadTakesOver: Bool = NotchPriorityPolicy.defaultDownloadTakesOver,
                privacyPreemptsTransientHUDs: Bool = NotchPriorityPolicy.defaultPrivacyPreemptsTransientHUDs) {
        self.downloadTakesOver = downloadTakesOver
        self.privacyPreemptsTransientHUDs = privacyPreemptsTransientHUDs
    }

    public static let standard = NotchPriorityPolicy()

    /// Rank of a surface under this policy. Positions are unique across surfaces.
    @inline(__always)
    public func rank(of surface: ClosedNotchSurface) -> NotchSurfaceRank {
        switch surface {
        case .connectivityHUD:      return .connectivity
        case .hello:                return .hello
        case .privacyIndicator:
            return privacyPreemptsTransientHUDs ? .privacy : NotchSurfaceRank(position: 75, rankClass: .safety)
        case .batteryHUD:           return .battery
        case .criticalNotification: return .criticalAlert
        case .systemHUD:            return .systemHUD
        case .appNotification:      return .appNotification
        case .capsLockIndicator:    return .capsLock
        case .download:
            return downloadTakesOver ? NotchSurfaceRank(position: 85, rankClass: .sticky)
                                     : NotchSurfaceRank(position: 125, rankClass: .sticky)
        case .music:                return .music
        case .timer:                return .timer
        case .reminder:             return .reminder
        case .recording:            return .recording
        case .localSend:            return .localSend
        case .focus:                return .focus
        case .extensionStandalone:  return .extensionActivity
        case .shelf:                return .shelf
        case .idle:                 return .idle
        case .header:               return .header
        case .empty:                return .empty
        }
    }
}

// MARK: - Vocabulary shared by snapshot and resolution

/// What the closed notch draws as its primary surface. One case per branch of today's chain (ContentView.swift:1046-1164)
/// plus the two new notification rows.
public enum ClosedNotchSurface: Equatable, Sendable {
    case connectivityHUD
    case hello
    case privacyIndicator
    case batteryHUD
    case criticalNotification   // NEW (rank 5)
    case systemHUD              // today's "inline HUD" branch (volume, brightness, backlight, bluetooth, AirPods mode, other)
    case appNotification        // NEW (rank 7)
    case capsLockIndicator      // the persistent indicator, not the sneak peek
    case download
    case music(badge: MusicBadge?)
    case timer
    case reminder
    case recording
    case localSend
    case focus
    case extensionStandalone
    case shelf
    case idle
    case header                 // notch is open
    case empty
}

/// Secondary slot drawn next to the music wings (ContentView.swift:1508-1540). Order: timer > reminder > recording >
/// focus > caps lock > extension > shelf.
public enum MusicBadge: Equatable, Sendable {
    case timer, reminder, recording, focus, capsLock, extensionPayload, shelf
}

/// The expansion slot (`coordinator.expandingView.type`) as seen on THIS screen. `.timer`, `.reminder`, `.doNotDisturb`
/// and `.privacy` are never set by any producer today (audit 2.5) but the guards that mention them are preserved.
public enum ExpansionKind: Equatable, Sendable, CaseIterable {
    case battery, music, timer, reminder, recording, download, doNotDisturb, privacy, lockScreen, other
}

/// The sneak-peek slot (`coordinator.sneakPeek.type`) as seen on THIS screen.
public enum SneakKind: Equatable, Sendable, CaseIterable {
    case volume, brightness, backlight
    case bluetooth
    case airPodsMode          // bluetoothAudio with value < 0 and a listening-mode icon (ContentView.swift:1093-1095)
    case capsLock
    case music, battery, timer, reminder
    case extensionActivity
    case other                // mic, download, recording, doNotDisturb, privacy, lockScreen: no producer today
    case notification         // NEW: app notification (normal/high)
    case criticalNotification // NEW: critical notification

    /// New kinds introduced by the notification feature. An unchanged chain would treat them as `.other`.
    public var isNotificationKind: Bool { self == .notification || self == .criticalNotification }

    /// volume/brightness/backlight are only drawn inline while the notch is closed.
    @inline(__always) var isLevelHUD: Bool { self == .volume || self == .brightness || self == .backlight }

    /// The two copy-pasted type lists (ContentView.swift:1113 and :1167) in one place: kinds that never render as the
    /// inline HUD (they have their own rendering).
    @inline(__always) var rendersAsInlineHUD: Bool {
        switch self {
        case .music, .battery, .timer, .reminder, .extensionActivity, .notification, .criticalNotification: return false
        default: return true
        }
    }
}

public enum BatteryHUDSpec: Equatable, Sendable, CaseIterable {
    case compact        // charging, and low/full in compact style: closed width + 180
    case standardLow    // closed width + 100, height + 75
    case standardFull   // closed width + 80, height + 70

    public var extraWidth: Double {
        switch self { case .compact: return 180; case .standardLow: return 100; case .standardFull: return 80 }
    }
    public var extraHeight: Double {
        switch self { case .compact: return 0; case .standardLow: return 75; case .standardFull: return 70 }
    }
}

// MARK: - Snapshot

/// Everything the resolver needs, flattened. Feature toggles are folded into the booleans by the builder (e.g.
/// `timerActive = timerLiveActivityEnabled && timerManager.isTimerActive`), because every toggle is read in the same
/// place as its state in today's chain. Every field is an Equatable value, so a snapshot can be logged and replayed.
public struct ClosedNotchSnapshot: Equatable, Sendable {
    // Structural
    public var notchClosed = true                  // vm.notchState == .closed
    public var hideOnClosed = false                // vm.hideOnClosed
    public var isLocked = false                    // lockScreenManager.isLocked
    public var connectivityHUDVisible = false      // isConnectivityHUDVisible (already implies closed, !hide, !locked)
    public var connectivityNoConnection = false    // hudState == .noConnection (clip shape only)
    public var firstLaunch = false                 // coordinator.firstLaunch

    // Expansion slot
    public var expansion: ExpansionKind? = nil     // currentScreenExpansionType (nil unless visible on this screen)
    public var expansionShownAnywhere = false      // coordinator.expandingView.show (the shelf branch reads this raw value)
    public var batteryHUD: BatteryHUDSpec = .compact  // meaningful when expansion == .battery

    // Sneak slot
    public var sneak: SneakKind? = nil             // nil unless a sneak peek is visible on this screen
    public var sneakArrivalSeq: UInt64 = 0         // scheduler arrivalSeq of the visible sneak peek (key output only)
    public var inlineHUDEnabled = true             // Defaults[.inlineHUD]
    public var activeSneakStyleStandard = true     // resolvedSneakPeekStyle() == .standard (extension payloads: always true)
    public var globalSneakStyleInline = false      // Defaults[.sneakPeekStyles] == .inline
    public var enableSneakPeek = true              // Defaults[.enableSneakPeek]
    public var notificationCardExpanded = false    // NEW: hover/click expanded card for the notification surfaces

    // Sticky eligibility
    public var musicPairingEligible = false        // isClosedMusicPairingEligible(...) (already implies closed, !hide, !locked)
    public var capsLockActive = false              // isCapsLockActive && enableCapsLockIndicator
    public var timerActive = false                 // isTimerActive && timerLiveActivityEnabled
    public var reminderActive = false              // reminderManager.isActive && enableReminderLiveActivity
    public var reminderEntryPresent = false        // reminderManager.activeReminder != nil
    public var recordingActive = false             // isRecording && enableScreenRecordingDetection && showRecordingIndicator
    public var recordingExpandedPresentation = false  // recordingHUDLayout.presentation == .expanded (hover-driven)
    public var downloadActive = false              // isDownloading && enableDownloadListener
    public var localSendActive = false             // localSendLiveActivityActive
    public var focusActive = false                 // enableDND && showDNDIndicator && isDoNotDisturbActive
    public var focusToastDismissing = false        // enableDND && showDNDIndicator && isFocusToastDismissing
    public var privacyActive = false               // hasAnyIndicator && (enableCameraDetection || enableMicrophoneDetection)
    public var extensionPayloadCount = 0           // active extension live activities (sortedActivities().count)
    public var extensionCoexistPayload = false     // a music-coexistence payload exists (resolvedExtensionMusicPayload() != nil)
    public var extensionStandaloneEnabled = true   // enableExtensionLiveActivities && effectiveClosedNotchHeight > 0
    public var shelfVisible = false                // !shelfState.isEmpty && !enableMinimalisticUI
    public var idleEligible = false                // !isPlaying && isPlayerIdle && showNotHumanFace

    public init() {}

    /// Combinations a real builder can never produce. Used to prune the exhaustive/sampled tests.
    public var isConsistent: Bool {
        if connectivityHUDVisible && !(notchClosed && !hideOnClosed && !isLocked) { return false }
        if musicPairingEligible && !(notchClosed && !hideOnClosed && !isLocked) { return false }
        if expansion != nil && !expansionShownAnywhere { return false }
        if extensionCoexistPayload && extensionPayloadCount < 1 { return false }
        if sneak == .extensionActivity && !activeSneakStyleStandard { return false }
        return true
    }
}

// MARK: - Resolution

public enum ClosedNotchSizing: Equatable, Sendable {
    case tabDriven                     // no surface-specific size: dynamicNotchSize / window use the tab-driven size
    case connectivity
    case airPodsInlineHUD
    case inlineMusicTimer              // 460 wide inline sneak expansion
    case recording                     // closed + RecordingHUDLayout extra width/height
    case battery(BatteryHUDSpec)
    case notificationCard              // NEW: card hanging below the notch
}

public enum ClosedNotchClip: Equatable, Sendable {
    case standard                      // pill or notch shape as today
    case connectivity(noConnection: Bool)
    case recordingExpanded
    case battery(BatteryHUDSpec)
    case notificationCard
}

/// The additive block drawn UNDER the primary surface (ContentView.swift:1166-1249).
public enum SneakOverlay: Equatable, Sendable {
    case none
    case systemEventIndicator          // SystemEventIndicatorModifier (when inlineHUD is off)
    case musicMarquee
    case timerMarquee
    case reminderMarquee
    case extensionMarquee
}

public struct ClosedNotchResolution: Equatable, Sendable {
    public var surface: ClosedNotchSurface
    public var key: NotchPriorityKey
    public var sizing: ClosedNotchSizing
    public var clip: ClosedNotchClip
    public var overlay: SneakOverlay

    public var rank: NotchSurfaceRank { key.rank }
    /// The compositor must apply a surface-specific size instead of the tab-driven one (view max-size AND window).
    public var growsWindow: Bool { sizing != .tabDriven }
    /// The surface hangs below the closed notch (battery standard styles, recording expanded, notification card).
    public var growsWindowHeight: Bool {
        switch sizing {
        case .battery(let spec): return spec.extraHeight > 0
        case .notificationCard: return true
        default: return false
        }
    }
}

// MARK: - The resolver

/// ONE pure function. Cost: a handful of boolean tests; no allocation.
public func resolveClosedNotchSurface(_ s: ClosedNotchSnapshot,
                                      policy: NotchPriorityPolicy = .standard) -> ClosedNotchResolution {
    let closed = s.notchClosed
    let calm = closed && !s.hideOnClosed

    // D1 == false: a download expansion is just another row and suppresses nothing.
    let dropDownloadExpansion = !policy.downloadTakesOver && s.expansion == .download
    let exp: ExpansionKind? = dropDownloadExpansion ? nil : s.expansion
    let expVisible = exp != nil                                                         // isCurrentScreenExpansionVisible
    let expShownRaw = dropDownloadExpansion ? false : s.expansionShownAnywhere          // coordinator.expandingView.show

    var best: ClosedNotchSurface = .empty
    var bestRank = policy.rank(of: .empty)
    func consider(_ surface: ClosedNotchSurface) {
        let r = policy.rank(of: surface)
        if r.position < bestRank.position { best = surface; bestRank = r }
    }

    // --- STRUCTURAL
    if s.connectivityHUDVisible { consider(.connectivityHUD) }
    if s.firstLaunch { consider(.hello) }

    // The lock-screen takeover blanks the notch (separate lock windows draw the real UI): nothing new cuts through it.
    let lockTakeover = exp == .lockScreen

    // --- SAFETY. No expansion guard (except the lock-screen takeover): the indicator stays visible until camera/mic
    // stop (fixes B8).
    if s.privacyActive && calm && !lockTakeover { consider(.privacyIndicator) }

    // --- TRANSIENT
    if exp == .battery && closed { consider(.batteryHUD) }

    let sneak = s.sneak
    let notificationVisible = (sneak?.isNotificationKind ?? false) && calm && !s.isLocked && !lockTakeover
    if notificationVisible {
        consider(sneak == .criticalNotification ? .criticalNotification : .appNotification)
    }
    if let k = sneak, k.rendersAsInlineHUD,
       s.inlineHUDEnabled || k == .airPodsMode,
       !k.isLevelHUD || closed {
        consider(.systemHUD)
    }

    // --- STICKY
    if closed && s.capsLockActive && calm && !s.isLocked { consider(.capsLockIndicator) }

    let musicBadge: MusicBadge? = s.musicPairingEligible ? resolveMusicBadge(s) : nil
    let expectedExpansionForBadge: ExpansionKind? = {
        switch musicBadge {
        case .timer?: return .timer
        case .reminder?: return .reminder
        case .recording?: return .recording
        case .focus?: return .doNotDisturb
        default: return nil
        }
    }()
    let canShowMusicDuringExpansion = !expVisible || exp == .music
        || (expectedExpansionForBadge != nil && exp == expectedExpansionForBadge)
    if canShowMusicDuringExpansion && s.musicPairingEligible { consider(.music(badge: musicBadge)) }

    if (exp == nil || exp == .timer) && calm && s.timerActive { consider(.timer) }
    if (exp == nil || exp == .reminder) && calm && s.reminderActive { consider(.reminder) }
    if (exp == nil || exp == .recording) && calm && s.recordingActive && !s.musicPairingEligible { consider(.recording) }
    if (exp == nil || exp == .download) && calm && s.downloadActive { consider(.download) }
    if !expVisible && calm && s.localSendActive { consider(.localSend) }
    if (exp == nil || exp == .doNotDisturb) && calm && (s.focusActive || s.focusToastDismissing) && !s.isLocked {
        consider(.focus)
    }

    let standalonePayloads = s.extensionPayloadCount - (musicBadge == .extensionPayload ? 1 : 0)
    if s.extensionStandaloneEnabled && standalonePayloads > 0 && calm && !s.isLocked && !expVisible {
        consider(.extensionStandalone)
    }

    // --- AMBIENT
    if !expShownRaw && calm && s.shelfVisible && !s.isLocked { consider(.shelf) }
    if !expVisible && calm && s.idleEligible { consider(.idle) }
    if !closed { consider(.header) }

    // --- Geometry and overlay follow the winner (kills the three-copy problem, bug B1).
    let sizing = closedNotchSizing(for: best, snapshot: s)
    let clip = closedNotchClip(for: best, snapshot: s)
    let overlay = closedNotchOverlay(snapshot: s)
    let isSneakSurface = best == .criticalNotification || best == .appNotification || best == .systemHUD
    let key = NotchPriorityKey(rank: bestRank, subrank: 0, arrivalSeq: isSneakSurface ? s.sneakArrivalSeq : 0)
    return ClosedNotchResolution(surface: best, key: key, sizing: sizing, clip: clip, overlay: overlay)
}

/// Music secondary slot (ContentView.swift:1508-1540). Only meaningful when music pairing is eligible.
@inline(__always)
func resolveMusicBadge(_ s: ClosedNotchSnapshot) -> MusicBadge? {
    if s.timerActive { return .timer }
    if s.reminderActive && s.reminderEntryPresent { return .reminder }
    if s.recordingActive { return .recording }
    if s.focusActive { return .focus }
    if s.capsLockActive { return .capsLock }
    if s.musicPairingEligible && s.extensionCoexistPayload { return .extensionPayload }
    if s.shelfVisible && !s.isLocked { return .shelf }
    return nil
}

/// Surface-specific size. The only place that decides it; ContentView.dynamicNotchSize and
/// DynamicIslandApp.calculateRequiredNotchSize both consume it.
func closedNotchSizing(for surface: ClosedNotchSurface, snapshot s: ClosedNotchSnapshot) -> ClosedNotchSizing {
    switch surface {
    case .connectivityHUD:
        return .connectivity
    case .batteryHUD:
        return .battery(s.batteryHUD)
    case .criticalNotification, .appNotification:
        return s.notificationCardExpanded ? .notificationCard : .tabDriven
    case .systemHUD where s.sneak == .airPodsMode && s.notchClosed && s.enableSneakPeek:
        return .airPodsInlineHUD
    default:
        break
    }
    // The 460-wide inline sneak expansion belongs to the expansion slot, not to a surface.
    if s.notchClosed && s.enableSneakPeek && s.globalSneakStyleInline && (s.expansion == .music || s.expansion == .timer) {
        return .inlineMusicTimer
    }
    if surface == .recording { return .recording }
    return .tabDriven
}

func closedNotchClip(for surface: ClosedNotchSurface, snapshot s: ClosedNotchSnapshot) -> ClosedNotchClip {
    switch surface {
    case .connectivityHUD:
        return .connectivity(noConnection: s.connectivityNoConnection)
    case .recording:
        return s.recordingExpandedPresentation ? .recordingExpanded : .standard
    case .batteryHUD:
        return .battery(s.batteryHUD)
    case .criticalNotification, .appNotification:
        return s.notificationCardExpanded ? .notificationCard : .standard
    default:
        return .standard
    }
}

/// The additive under-notch block (ContentView.swift:1166-1249). Independent of the primary winner, as today.
func closedNotchOverlay(snapshot s: ClosedNotchSnapshot) -> SneakOverlay {
    guard let k = s.sneak else { return .none }
    let closed = s.notchClosed
    switch k {
    case .music:
        return (closed && !s.hideOnClosed && s.activeSneakStyleStandard) ? .musicMarquee : .none
    case .timer:
        return (!s.hideOnClosed && s.activeSneakStyleStandard) ? .timerMarquee : .none
    case .reminder:
        return (!s.hideOnClosed && s.activeSneakStyleStandard && s.reminderEntryPresent) ? .reminderMarquee : .none
    case .extensionActivity:
        return (!s.hideOnClosed && s.activeSneakStyleStandard) ? .extensionMarquee : .none
    case .battery, .capsLock, .notification, .criticalNotification:
        return .none
    default:
        // volume, brightness, backlight, bluetooth, airPodsMode, other
        let isAirPods = k == .airPodsMode
        return (!s.inlineHUDEnabled && !isAirPods && (!k.isLevelHUD || closed)) ? .systemEventIndicator : .none
    }
}

// MARK: - Sneak classification (feeds SneakPeekScheduler)

public enum NotchSneakPriority: Int, Comparable, Sendable, CaseIterable {
    case low = 0, normal, high, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum NotchSneakClassifier {
    /// (rank, subrank) of a sneak-peek item for the scheduler.
    ///  * critical priority (any kind but system HUDs): rank 5, so a critical reminder or critical extension activity
    ///    cannot be overwritten by a lower rank (bug B10);
    ///  * system HUDs: rank 6; Bluetooth/AirPods subrank 0 so a volume press never cuts them short (bug B6);
    ///  * everything else (app notification, extension, music, timer, reminder): rank 7, subrank by priority.
    public static func classify(kind: SneakKind, priority: NotchSneakPriority = .normal) -> (rank: NotchSurfaceRank, subrank: Int) {
        switch kind {
        case .bluetooth, .airPodsMode: return (.systemHUD, 0)
        case .volume, .brightness, .backlight: return (.systemHUD, 1)
        case .capsLock: return (.systemHUD, 2)
        case .other: return (.systemHUD, 3)
        case .criticalNotification: return (.criticalAlert, 0)
        case .music, .battery, .timer, .reminder, .extensionActivity, .notification:
            if priority == .critical { return (.criticalAlert, 0) }
            switch priority {
            case .high: return (.appNotification, 0)
            case .normal: return (.appNotification, 1)
            default: return (.appNotification, 2)
            }
        }
    }
}
