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

// REFERENCE ORACLE: today's closed-notch decision logic, transcribed branch by branch from the live code as of
// docs/NOTIFICATIONS-IDLE-AUDIT.md (HEAD 6294efa, local-build). Do not "improve" it: its job is to be wrong in exactly
// the ways the app is wrong today, so the differential test can prove every deviation of the new resolver is intended.
//
//   chain          Toplet/ContentView.swift:1046-1164 (NotchLayout)
//   music badge    Toplet/ContentView.swift:1508-1540 (resolveMusicSecondaryLiveActivity)
//   overlay        Toplet/ContentView.swift:1166-1249 (additive block under the primary surface)
//   view size      Toplet/ContentView.swift:112-243   (dynamicNotchSize)
//   window size    Toplet/DynamicIslandApp.swift:491-610 (calculateRequiredNotchSize)
//   clip           Toplet/ContentView.swift:561-636   (activeClosed*SurfaceShape + resolvedClipShape)
//   standalone ext Toplet/ContentView.swift:1898-1985 (resolvedExtensionStandalonePayload)
//
// Inputs are the fields of ClosedNotchSnapshot, which are the same booleans those lines read (feature toggles folded in).
// The two NEW sneak kinds (.notification, .criticalNotification) do not exist in the old code; the oracle treats them as
// `.other`, which is what an unmodified chain would do with an unknown type (audit 4.2).

enum OldBadge: Equatable { case timer, reminder, recording, focus, capsLock, ext, shelf }

enum OldSurface: Equatable {
    case connectivity, hello, battery, inlineHUD, capsPersistent
    case music(OldBadge?)
    case timer, reminder, recording, download, localSend, focus, privacy, extStandalone, shelf, idle, header, empty
}

enum OldOverlay: Equatable { case none, systemEvent, music, timer, reminder, ext }
enum OldSizing: Equatable { case tab, connectivity, airPods, inline460, recording, battery(BatteryHUDSpec) }
enum OldClip: Equatable { case standard, connectivity(Bool), recordingExpanded, battery(BatteryHUDSpec) }

/// What an unmodified chain makes of the sneak peek kind.
private func oldKind(_ k: SneakKind?) -> SneakKind? {
    guard let k else { return nil }
    return k.isNotificationKind ? .other : k
}

/// resolveMusicSecondaryLiveActivity(isMusicPairingEligible:), ContentView.swift:1508-1540.
private func oldMusicSecondary(_ s: ClosedNotchSnapshot) -> OldBadge? {
    if s.timerActive { return .timer }
    if s.reminderActive, s.reminderEntryPresent { return .reminder }
    if s.recordingActive { return .recording }
    if s.focusActive { return .focus }
    if s.capsLockActive { return .capsLock }
    if s.musicPairingEligible, s.extensionCoexistPayload { return .ext }
    if s.shelfVisible && !s.isLocked { return .shelf }
    return nil
}

/// resolvedExtensionStandalonePayload(excluding:) != nil, ContentView.swift:1898-1985.
private func oldExtensionStandalonePresent(_ s: ClosedNotchSnapshot, secondary: OldBadge?) -> Bool {
    let base = s.extensionPayloadCount
    guard base > 0 else { return false }
    let candidates = base - (secondary == .ext ? 1 : 0)       // filter { $0.id != musicPayloadID }
    guard candidates > 0 else { return false }
    guard s.extensionStandaloneEnabled else { return false }  // enableExtensionLiveActivities, effectiveClosedNotchHeight > 0
    guard s.notchClosed else { return false }
    guard !s.hideOnClosed else { return false }
    guard !s.isLocked else { return false }
    guard s.expansion == nil else { return false }            // !isCurrentScreenExpansionVisible
    return true
}

func oldChain(_ s: ClosedNotchSnapshot) -> OldSurface {
    let closed = s.notchClosed
    let hideOnClosed = s.hideOnClosed
    let isLocked = s.isLocked
    let isCurrentScreenExpansionVisible = s.expansion != nil
    let currentScreenExpansionType = s.expansion
    let sneakType = oldKind(s.sneak)
    let isSneakPeekVisibleOnCurrentScreen = s.sneak != nil

    if s.connectivityHUDVisible {                                                                    // :1046
        return .connectivity
    } else if s.firstLaunch {                                                                        // :1052
        return .hello
    } else {
        let musicPairingEligible = s.musicPairingEligible                                            // :1066
        let musicSecondary = oldMusicSecondary(s)                                                    // :1067
        let extensionStandalonePresent = oldExtensionStandalonePresent(s, secondary: musicSecondary) // :1068-1069
        let expansionMatchesSecondary: Bool = {                                                      // :1071-1089
            guard let musicSecondary else { return false }
            switch musicSecondary {
            case .timer: return currentScreenExpansionType == .timer
            case .reminder: return currentScreenExpansionType == .reminder
            case .recording: return currentScreenExpansionType == .recording
            case .focus: return currentScreenExpansionType == .doNotDisturb
            case .capsLock: return false
            case .ext: return false
            case .shelf: return false
            }
        }()
        let canShowMusicDuringExpansion = !isCurrentScreenExpansionVisible                          // :1090-1092
            || currentScreenExpansionType == .music
            || expansionMatchesSecondary
        let isAirPodsListeningModeSneak = sneakType == .airPodsMode                                  // :1093-1095

        if currentScreenExpansionType == .battery                                                    // :1097-1101
            && closed {
            return .battery
        } else if isSneakPeekVisibleOnCurrentScreen && (s.inlineHUDEnabled || isAirPodsListeningModeSneak)   // :1113
                    && (sneakType != .music) && (sneakType != .battery) && (sneakType != .timer) && (sneakType != .reminder)
                    && !(sneakType == .extensionActivity)
                    && ((sneakType != .volume && sneakType != .brightness && sneakType != .backlight) || closed) {
            return .inlineHUD
        } else if closed && s.capsLockActive && !hideOnClosed && !isLocked {                         // :1120
            return .capsPersistent
        } else if canShowMusicDuringExpansion && musicPairingEligible {                              // :1123
            return .music(musicSecondary)
        } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .timer) && closed && s.timerActive && !hideOnClosed {         // :1127
            return .timer
        } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .reminder) && closed && s.reminderActive && !hideOnClosed {   // :1129
            return .reminder
        } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .recording) && closed && s.recordingActive && !hideOnClosed && !musicPairingEligible {  // :1131
            return .recording
        } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .download) && closed && s.downloadActive && !hideOnClosed {   // :1133
            return .download
        } else if !isCurrentScreenExpansionVisible && closed && s.localSendActive && !hideOnClosed { // :1136
            return .localSend
        } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .doNotDisturb) && closed
                    && (s.focusActive || s.focusToastDismissing) && !hideOnClosed && !isLocked {       // :1139
            return .focus
        } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .privacy) && closed && s.privacyActive && !hideOnClosed {    // :1141
            return .privacy
        } else if extensionStandalonePresent {                                                       // :1143
            return .extStandalone
        } else if !s.expansionShownAnywhere && closed && s.shelfVisible && !hideOnClosed && !isLocked {   // :1154 (coordinator.expandingView.show)
            return .shelf
        } else if !isCurrentScreenExpansionVisible && closed && s.idleEligible && !hideOnClosed {     // :1157
            return .idle
        } else if !closed {                                                                          // :1159
            return .header
        } else {                                                                                     // :1162
            return .empty
        }
    }
}

/// The additive block, ContentView.swift:1166-1249.
func oldOverlay(_ s: ClosedNotchSnapshot) -> OldOverlay {
    guard s.sneak != nil, let t = oldKind(s.sneak) else { return .none }       // if isSneakPeekVisibleOnCurrentScreen
    let closed = s.notchClosed
    let isAirPodsListeningModeSneak = t == .airPodsMode
    if (t != .music) && (t != .battery) && (t != .timer) && (t != .reminder) && (t != .capsLock)
        && !(t == .extensionActivity) && !s.inlineHUDEnabled && !isAirPodsListeningModeSneak
        && ((t != .volume && t != .brightness && t != .backlight) || closed) {                // :1167
        return .systemEvent
    } else if t == .music {                                                                   // :1176
        return (closed && !s.hideOnClosed && s.activeSneakStyleStandard) ? .music : .none
    } else if t == .timer {                                                                   // :1189
        return (!s.hideOnClosed && s.activeSneakStyleStandard) ? .timer : .none
    } else if t == .reminder {                                                                // :1201
        return (!s.hideOnClosed && s.activeSneakStyleStandard && s.reminderEntryPresent) ? .reminder : .none
    } else if t == .extensionActivity {                                                       // :1221
        return (!s.hideOnClosed && s.activeSneakStyleStandard) ? .ext : .none
    }
    return .none
}

/// RecordingHUDLayout.isVisible (helpers/RecordingHUDLayout.swift:108-114).
private func oldRecordingLayoutVisible(_ s: ClosedNotchSnapshot) -> Bool {
    s.notchClosed && s.recordingActive && !s.hideOnClosed && !s.musicPairingEligible
}

/// dynamicNotchSize, ContentView.swift:112-243 (the part that is not tab-driven).
func oldViewSizing(_ s: ClosedNotchSnapshot) -> OldSizing {
    if s.connectivityHUDVisible { return .connectivity }                                      // :115
    let airPodsListeningModeSneakActive = s.notchClosed && s.sneak != nil && oldKind(s.sneak) == .airPodsMode   // :126-130
    let inlineSneakPeekActive = s.notchClosed                                                 // :131-138
        && (
            (s.expansion == .music || s.expansion == .timer) && s.globalSneakStyleInline
                || airPodsListeningModeSneakActive
        )
        && s.enableSneakPeek
    if inlineSneakPeekActive {                                                                // :139
        return airPodsListeningModeSneakActive ? .airPods : .inline460
    }
    if oldRecordingLayoutVisible(s) { return .recording }                                     // :150
    if s.notchClosed && s.expansion == .battery { return .battery(s.batteryHUD) }             // :158-188
    return .tab
}

/// calculateRequiredNotchSize, DynamicIslandApp.swift:491-610. Same order; an inline sneak peek is a flat 460 for both
/// the AirPods mode and the music/timer expansion (the view copy computes the AirPods width instead).
func oldWindowSizing(_ s: ClosedNotchSnapshot) -> OldSizing {
    if s.connectivityHUDVisible { return .connectivity }                                      // :492
    let airPodsListeningModeSneakActive = s.notchClosed && s.sneak != nil && oldKind(s.sneak) == .airPodsMode   // :509-514
    let isInlineSneakPeekActive = s.notchClosed && s.enableSneakPeek                          // :515-522
        && (
            (s.expansion == .music || s.expansion == .timer) && s.globalSneakStyleInline
                || airPodsListeningModeSneakActive
        )
    if isInlineSneakPeekActive { return .inline460 }                                          // :525-530
    if oldRecordingLayoutVisible(s) { return .recording }                                     // :532-537
    if s.notchClosed && s.expansion == .battery { return .battery(s.batteryHUD) }             // :540-574
    return .tab
}

/// resolvedClipShape, ContentView.swift:612-636.
func oldClip(_ s: ClosedNotchSnapshot) -> OldClip {
    if s.connectivityHUDVisible { return .connectivity(s.connectivityNoConnection) }          // :613
    if oldRecordingLayoutVisible(s) && s.recordingExpandedPresentation { return .recordingExpanded }   // :626 (583-596)
    if s.notchClosed && s.expansion == .battery { return .battery(s.batteryHUD) }             // :629 (561-581)
    return .standard
}

// MARK: - Mapping between the new vocabulary and the oracle's

func oldBadge(_ b: MusicBadge?) -> OldBadge? {
    switch b {
    case nil: return nil
    case .timer?: return .timer
    case .reminder?: return .reminder
    case .recording?: return .recording
    case .focus?: return .focus
    case .capsLock?: return .capsLock
    case .extensionPayload?: return .ext
    case .shelf?: return .shelf
    }
}

/// nil for surfaces the old chain does not have.
func asOld(_ x: ClosedNotchSurface) -> OldSurface? {
    switch x {
    case .connectivityHUD: return .connectivity
    case .hello: return .hello
    case .privacyIndicator: return .privacy
    case .batteryHUD: return .battery
    case .criticalNotification, .appNotification: return nil
    case .systemHUD: return .inlineHUD
    case .capsLockIndicator: return .capsPersistent
    case .download: return .download
    case .music(let b): return .music(oldBadge(b))
    case .timer: return .timer
    case .reminder: return .reminder
    case .recording: return .recording
    case .localSend: return .localSend
    case .focus: return .focus
    case .extensionStandalone: return .extStandalone
    case .shelf: return .shelf
    case .idle: return .idle
    case .header: return .header
    case .empty: return .empty
    }
}

func asOld(_ x: SneakOverlay) -> OldOverlay {
    switch x {
    case .none: return .none
    case .systemEventIndicator: return .systemEvent
    case .musicMarquee: return .music
    case .timerMarquee: return .timer
    case .reminderMarquee: return .reminder
    case .extensionMarquee: return .ext
    }
}

func asOld(_ x: ClosedNotchSizing) -> OldSizing? {
    switch x {
    case .tabDriven: return .tab
    case .connectivity: return .connectivity
    case .airPodsInlineHUD: return .airPods
    case .inlineMusicTimer: return .inline460
    case .recording: return .recording
    case .battery(let b): return .battery(b)
    case .notificationCard: return nil
    }
}

/// The window copy cannot tell the AirPods width from the music/timer width (both are a flat 460).
func windowEquivalent(_ x: OldSizing) -> OldSizing { x == .airPods ? .inline460 : x }

func asOld(_ x: ClosedNotchClip) -> OldClip? {
    switch x {
    case .standard: return .standard
    case .connectivity(let n): return .connectivity(n)
    case .recordingExpanded: return .recordingExpanded
    case .battery(let b): return .battery(b)
    case .notificationCard: return nil
    }
}
