# Notch priority arbiter

Deterministic replacement for the closed-notch `if / else if` chain, its two size copies, its clip-shape copy and the
single-slot `sneakPeek` timer. Spec source: `docs/NOTIFICATIONS-IDLE-AUDIT.md` sections 2.6, 2.7, 6 (N1, E2, E3, E4) and 7.6 (T1, T2).

Status: the arbiter and its tests are complete and green. Nothing under `Toplet/` was edited; section 6 is the
step-by-step plan for the integrator. Everything in this document marked UNVERIFIED needs the live app or Xcode.

## 1. Files

| File | What |
|---|---|
| `AtollNotch/Core/NotchEventArbiter.swift` | `NotchSurfaceRank`, `NotchPriorityKey`, `NotchPriorityPolicy` (decisions D1/D2), `ClosedNotchSurface`, `ClosedNotchSnapshot`, `ClosedNotchResolution` (surface + geometry + overlay), `resolveClosedNotchSurface(_:policy:)`, `NotchSneakClassifier` |
| `AtollNotch/Core/NotchEventArbiterScheduler.swift` | `SneakPeekScheduler<Payload>`: value-type transient scheduler with an injected clock |
| `AtollNotch/Tests/ArbiterTestsOracle.swift` | today's chain transcribed line by line (the reference oracle) |
| `AtollNotch/Tests/ArbiterTestsDifferential.swift` | T1 differential, allow-list, enumeration |
| `AtollNotch/Tests/ArbiterTestsResolver.swift` | table, ladder, B8, D1, D2, new rows, B1 geometry, overlay, purity, performance |
| `AtollNotch/Tests/ArbiterTestsScheduler.swift` | T2 scenarios B2-B6, B10, rules, fuzz, determinism, soak |
| `AtollNotch/Tests/ArbiterTestSupport.swift`, `ArbiterTestRunner.swift` | assertion helpers, seeded RNG, `@main` |
| `AtollNotch/Tests/run_arbiter.sh` | `xcrun swiftc -swift-version 5 -parse-as-library -O` over `Core/NotchEventArbiter*.swift` + `Tests/Arbiter*.swift`; exit 1 on a failed check, 2 on a build failure |

Both Core files are Foundation-only and self-contained (no dependency on `NotchNotification.swift`). `-O` is deliberate: the
5 microsecond budget is meaningless at `-Onone`.

## 2. Model (what `resolveClosedNotchSurface` implements)

Total order key `(rank, subrank, arrivalSeq)`. Rank positions are the audit table rank x 10 so rank 8.5 exists.

| Pos | Surface (`ClosedNotchSurface`) | Class | Eligibility (all inputs are `ClosedNotchSnapshot` fields) |
|---:|---|---|---|
| 10 | `connectivityHUD` | STRUCTURAL | `connectivityHUDVisible` |
| 20 | `hello` | STRUCTURAL | `firstLaunch` |
| 30 | `privacyIndicator` | SAFETY | `privacyActive && closed && !hideOnClosed`, no expansion guard (B8), still blanked by the `.lockScreen` takeover |
| 40 | `batteryHUD` | TRANSIENT | `expansion == .battery && closed` |
| 50 | `criticalNotification` NEW | TRANSIENT | `sneak == .criticalNotification && closed && !hide && !locked`, not under `.lockScreen` |
| 60 | `systemHUD` (today's inline HUD) | TRANSIENT | the old branch-4 predicate (`SneakKind.rendersAsInlineHUD`, `inlineHUDEnabled \|\| airPodsMode`, level HUDs only while closed) |
| 70 | `appNotification` NEW | TRANSIENT | as critical, `sneak == .notification` |
| 80 | `capsLockIndicator` (persistent) | STICKY | `capsLockActive && closed && !hide && !locked` |
| 85 | `download` (D1, explicit) | STICKY | `(expansion == nil \|\| .download) && closed && !hide && downloadActive` |
| 90 | `music(badge:)` | STICKY | `musicPairingEligible && (no expansion \|\| .music \|\| expansion equals the badge's)` |
| 100 | `timer` | STICKY | `(exp nil \|\| .timer) && calm && timerActive` |
| 110 | `reminder` | STICKY | `(exp nil \|\| .reminder) && calm && reminderActive` |
| 120 | `recording` | STICKY | `(exp nil \|\| .recording) && calm && recordingActive && !musicPairingEligible` |
| 140 | `localSend` | STICKY | `no expansion && calm && localSendActive` |
| 150 | `focus` | STICKY | `(exp nil \|\| .doNotDisturb) && calm && (focusActive \|\| focusToastDismissing) && !locked` |
| 160 | `extensionStandalone` | STICKY | enabled, payloads left after the music badge took one, `calm && !locked && no expansion` |
| 170 | `shelf` | AMBIENT | `!expansionShownAnywhere && calm && shelfVisible && !locked` |
| 180 | `idle` | AMBIENT | `no expansion && calm && idleEligible` |
| 190 / 200 | `header` / `empty` | AMBIENT | notch open / nothing |

`calm = closed && !hideOnClosed`. The expansion guards of today's chain are preserved for every row that had one
(`isCurrentScreenExpansionVisible` semantics, audit 2.5): an expansion of another kind still suppresses timer, reminder,
recording, download, localSend, focus, extension, idle and (unless it is the music wings' own badge) music.

`music(badge:)` carries the secondary slot, order timer > reminder > recording > focus > caps lock > extension > shelf
(`ContentView.swift:1508-1540`, unchanged and tested).

### Decisions (single constants, `NotchPriorityPolicy`)

* **D1** `defaultDownloadTakesOver = true` (audit default). Download is rank 8.5: above music, timer, reminder and recording
  whenever it runs, not only while the single expansion slot happens to hold `.download`. `false` demotes it to 12.5 and
  stops a `.download` expansion from suppressing the others. Tested both ways.
* **D2** `defaultPrivacyPreemptsTransientHUDs = true` (the audit table literally: privacy rank 3, rule 6 "SAFETY never
  preempted by TRANSIENT"). Consequence to be aware of: while the camera or mic is in use, the inline volume/brightness HUD,
  the charging HUD and notifications are NOT drawn (the scheduler still counts their TTL down). `false` puts privacy at 7.5:
  lifted above music/timer/download (the B8 fix) but below the transient HUDs. Flip this constant if that is not wanted.
  Tested both ways.

### Geometry follows the winner

`ClosedNotchResolution` also carries `sizing` (`tabDriven`, `connectivity`, `airPodsInlineHUD`, `inlineMusicTimer`,
`recording`, `battery(BatteryHUDSpec)`, `notificationCard`), `clip` (`standard`, `connectivity(noConnection:)`,
`recordingExpanded`, `battery(spec)`, `notificationCard`) and `overlay` (`none`, `systemEventIndicator`, the four marquees),
plus `growsWindow` / `growsWindowHeight`. `dynamicNotchSize`, `calculateRequiredNotchSize` and `resolvedClipShape` all read
these, so recording can no longer size the window for the charging HUD (B1).

## 3. Snapshot: where each field comes from

All feature toggles are folded in (the chain reads every toggle next to its state). A builder (section 6, step 1) fills this once.

| Field | Source today |
|---|---|
| `notchClosed`, `hideOnClosed`, `isLocked` | `vm.notchState == .closed`, `vm.hideOnClosed`, `lockScreenManager.isLocked` |
| `connectivityHUDVisible`, `connectivityNoConnection` | `isConnectivityHUDVisible` (`ContentView.swift:451`), `networkConnectivityManager.hudState == .noConnection` |
| `firstLaunch` | `coordinator.firstLaunch` |
| `expansion` | `currentScreenExpansionType` (`ContentView.swift:511`), mapped to `ExpansionKind` |
| `expansionShownAnywhere` | `coordinator.expandingView.show` (the shelf branch reads the raw value) |
| `batteryHUD` | `batteryModel.activeTemporaryHUDKind` + `lowBatteryHUDStyle` / `fullBatteryHUDStyle`: charging -> `.compact`; low/full compact -> `.compact`; low standard -> `.standardLow`; full standard -> `.standardFull` |
| `sneak` | `coordinator.sneakPeek.type` if `isSneakPeekVisibleOnCurrentScreen` (`:434`), mapped to `SneakKind`; `.bluetoothAudio` with `value < 0 && AirPodsListeningMode.fromHUDSymbol(icon) != nil` becomes `.airPodsMode` (the magic value now lives in ONE place) |
| `sneakArrivalSeq` | `SneakPeekItem.key.arrivalSeq` of the visible item |
| `inlineHUDEnabled`, `enableSneakPeek` | `Defaults[.inlineHUD]`, `Defaults[.enableSneakPeek]` |
| `activeSneakStyleStandard` | `resolvedSneakPeekStyle() == .standard` (`:2981`; extension payloads always true) |
| `globalSneakStyleInline` | `Defaults[.sneakPeekStyles] == .inline` |
| `notificationCardExpanded` | UI state of the notification card (hover/click) |
| `musicPairingEligible` | `closedMusicPairingEligible(hasActiveMusicSnapshot:)` (`:369`) / `closedMusicPairingEligibleForSizing()` (`DynamicIslandApp.swift:629`), unchanged |
| `capsLockActive` | `capsLockManager.isCapsLockActive && enableCapsLockIndicator` |
| `timerActive` | `timerManager.isTimerActive && coordinator.timerLiveActivityEnabled` |
| `reminderActive`, `reminderEntryPresent` | `reminderManager.isActive && enableReminderLiveActivity`, `reminderManager.activeReminder != nil` |
| `recordingActive`, `recordingExpandedPresentation` | `recordingManager.isRecording && enableScreenRecordingDetection && showRecordingIndicator`; `recordingHUDLayout.presentation == .expanded` (`isHovering` for the view, `true` for the window, exactly as the two copies do today) |
| `downloadActive`, `localSendActive` | `downloadManager.isDownloading && Defaults[.enableDownloadListener]`, `localSendLiveActivityActive` (`:468`) |
| `focusActive`, `focusToastDismissing` | `enableDoNotDisturbDetection && showDoNotDisturbIndicator && ` `doNotDisturbManager.isDoNotDisturbActive` / `.isFocusToastDismissing` |
| `privacyActive` | `privacyManager.hasAnyIndicator && (enableCameraDetection \|\| enableMicrophoneDetection)` |
| `extensionPayloadCount`, `extensionCoexistPayload`, `extensionStandaloneEnabled` | `extensionLiveActivityManager.sortedActivities().count`, `sortedActivities(for: true).first != nil`, `enableExtensionLiveActivities && vm.effectiveClosedNotchHeight > 0` |
| `shelfVisible` | `!shelfState.isEmpty && !enableMinimalisticUI` |
| `idleEligible` | `!musicManager.isPlaying && musicManager.isPlayerIdle && Defaults[.showNotHumanFace]` |

`ClosedNotchSnapshot.isConsistent` lists the combinations a builder can never produce (connectivity or music pairing implies
closed, not hidden, not locked; a visible expansion implies `expansionShownAnywhere`; ...). The tests prune with it.

## 4. Intentional differences from today (the allow-list)

T1 compares the new resolver to the transcribed old logic for surface, overlay, view size, window size and clip, and excuses a
difference only through one of four entries, each with a precise predicate; each must fire at least once.

| Entry | What changes | Why | Predicate (test) |
|---|---|---|---|
| **B8** | Camera/mic indicator wins over everything except connectivity/hello (D2), including music, timer, reminder, recording, download, caps lock, the charging HUD, system HUDs; the expansion guard is gone | audit B8: with default settings and music playing it was never drawn | new == privacy, old != privacy, `privacyActive && closed && !hide && expansion != .lockScreen` |
| **D1** | Download beats music/timer/reminder/recording whenever it runs and no other expansion is visible | audit B7/D1: make "download takes over" explicit instead of depending on which expansion holds the slot | new == download, old in {music, timer, reminder, recording}, `expansion == nil`, `downloadActive && closed && !hide` |
| **B1** | View size, window size and clip shape follow the winning surface | audit B1/2.3: recording, an AirPods sneak and the battery clip were keyed on "is on" instead of "won"; also fixes the privacy indicator, timer, reminder, focus and download being drawn in the narrow recording-sized window | new geometry equals the winner's spec; the old geometry's owner (recording / AirPods / battery) was NOT the old winner |
| **NEW** | App notification (rank 7) and critical notification (rank 5) | new rows | with a notification sneak: either its own surface (no overlay, spec geometry) or identical to the same state without it |

An unchanged chain would have drawn a notification as an inline HUD (audit 4.2); the oracle models that as `.other`.
Overlays are never allowed to differ for old kinds, and never did.

Counts from the last run (deterministic seeds): 1,729,984 states compared, 1,140,571 identical to today, 589,413 differ only
through the allow-list (B8 279,048; B1 154,027; NEW 144,829; D1 11,509), 0 unexplained. Run
`ARBITER_DETAIL=1 AtollNotch/Tests/run_arbiter.sh` for the per-reason breakdown (which old winner each entry replaced).

## 5. Scheduler (`SneakPeekScheduler<Payload>`)

Value type, injected clock (all calls take `now`, a monotonic `TimeInterval`; use `ProcessInfo.systemUptime`), no timers,
no `DispatchQueue`, no shared duration field.

* `offer(_:now:)` request = `(dedupeKey, rank, subrank, ttl, payload)`; result tells `showing / queued / replacedActive / replacedQueued / rejected(reason)` and which tokens expired, were dropped or superseded.
* `finish(token:now:)`, `finish(dedupeKey:now:)`: only the item holding that token/key is touched; any other value is a no-op (B3, B4, B5).
* `expire(now:)`: advance the clock; promotions happen at the logical expiry instant, so a late wake or extra redundant calls change nothing.
* `pause(now:)` / `resume(now:)` (hover), `clearAll(now:)` (lock screen), `nextDeadline`, `remaining(now:)`.
* Higher rank (strictly smaller position) preempts; the preempted item keeps `remaining` and resumes when it is the best waiting item. Equal or lower rank waits, ordered by `(rank, subrank, arrivalSeq)`.
* Same `dedupeKey` replaces (new token, ttl restarted, original `arrivalSeq` kept, old token invalidated).
* Queue capped (default 5; lowest priority, then oldest, evicted; a newcomer worse than everything in a full queue is rejected).
* STICKY (`ttl` not finite) is rejected: persistent indicators live in `ClosedNotchSnapshot`. ttl <= 0 or NaN is rejected; ttl is clamped to 120 s.
* `NotchSneakClassifier.classify(kind:priority:)` gives `(rank, subrank)`: critical priority -> rank 5; Bluetooth/AirPods -> rank 6 sub 0 (a volume press never cuts them short, B6); volume/brightness/backlight -> 6/1; caps lock 6/2; app notifications, extension, music, timer, reminder -> rank 7, subrank by priority (high 0, normal 1, low 2).

## 6. Integration plan (for the integrator; nothing below was applied)

Line numbers are from the current tree (`ContentView.swift` 3,287 lines). Compile status of the snippets: UNVERIFIED (no Xcode,
SwiftUI/Defaults are not available to the standalone harness); the resolver and scheduler themselves are compiled and tested.

### Step 0. Add the files

Copy (or have `local/prepare.py` pick up) `AtollNotch/Core/NotchEventArbiter.swift` and `NotchEventArbiterScheduler.swift` to
`Toplet/helpers/` (audit N1). No type name collides with anything under `Toplet/`, `AtollNotch/` or
`AtollAgents/` (checked by grep).

### Step 1. New file `Toplet/helpers/ClosedNotchSnapshotBuilder.swift`

One builder used by ContentView AND the window code, so they cannot disagree again. Sketch:

```swift
@MainActor
enum ClosedNotchSnapshotBuilder {
    static func make(vm: DynamicIslandViewModel, screenName: String,
                     musicPairingEligible: Bool, recordingExpanded: Bool) -> ClosedNotchSnapshot {
        let coordinator = DynamicIslandViewCoordinator.shared
        let battery = BatteryStatusViewModel.shared
        var s = ClosedNotchSnapshot()
        s.notchClosed = vm.notchState == .closed
        s.hideOnClosed = vm.hideOnClosed
        s.isLocked = LockScreenManager.shared.isLocked
        let net = NetworkConnectivityManager.shared
        s.connectivityHUDVisible = NetworkConnectivityHUDMetrics.isPresented(
            state: net.hudState, notchState: vm.notchState, hideOnClosed: vm.hideOnClosed, isLocked: s.isLocked)
        s.connectivityNoConnection = net.hudState == .noConnection
        s.firstLaunch = coordinator.firstLaunch

        let exp = coordinator.expandingView
        let batteryVisible = exp.show && exp.type == .battery
            && Defaults[.showPowerStatusNotifications] && battery.activeTemporaryHUDKind != nil
            && (Defaults[.showOnAllDisplays] || battery.activeTemporaryHUDTargetScreenName == nil
                || battery.activeTemporaryHUDTargetScreenName == screenName)
        s.expansionShownAnywhere = exp.show
        s.expansion = (exp.show && (exp.type != .battery || batteryVisible)) ? ExpansionKind(exp.type) : nil
        if let kind = battery.activeTemporaryHUDKind { s.batteryHUD = BatteryHUDSpec(kind: kind) }

        let sp = coordinator.sneakPeek
        let sneakVisible = sp.show && (!Defaults[.showOnAllDisplays] || sp.targetScreenName == nil
                                       || sp.targetScreenName == screenName)
        s.sneak = sneakVisible ? SneakKind(sp.type, value: sp.value, icon: sp.icon) : nil
        s.inlineHUDEnabled = Defaults[.inlineHUD]
        s.enableSneakPeek = Defaults[.enableSneakPeek]
        s.globalSneakStyleInline = Defaults[.sneakPeekStyles] == .inline
        s.activeSneakStyleStandard = (sp.type.isExtensionPayload ? .standard
                                      : (sp.styleOverride ?? Defaults[.sneakPeekStyles])) == .standard
        s.musicPairingEligible = musicPairingEligible
        s.recordingExpandedPresentation = recordingExpanded
        // ... the sticky booleans exactly as in the table of section 3
        return s
    }
}
// SneakKind.init(_ type: SneakContentType, value:, icon:): .bluetoothAudio -> (value < 0 && AirPodsListeningMode.fromHUDSymbol(icon) != nil) ? .airPodsMode : .bluetooth;
// .mic .download .recording .doNotDisturb .privacy .lockScreen -> .other; .notification(id:) (step 6) -> .notification.
// ExpansionKind.init(_ type: SneakContentType): battery, music, timer, reminder, recording, download, doNotDisturb, privacy, lockScreen; anything else -> .other.
```

### Step 2. `ContentView.swift:1042-1164` (the chain) -> one `switch`

Add next to the other private vars (near `ContentView.swift:511`):

```swift
private var closedSnapshot: ClosedNotchSnapshot {
    ClosedNotchSnapshotBuilder.make(vm: vm, screenName: currentScreenName,
        musicPairingEligible: closedMusicPairingEligible(hasActiveMusicSnapshot: hasActiveMusicSnapshotForClosedPairing),
        recordingExpanded: isHovering)
}
private var closedResolution: ClosedNotchResolution { resolveClosedNotchSurface(closedSnapshot) }
```

Before (`:1046-1164`, 119 lines of `if / else if`, plus the local `let`s `:1060-1095`). After:

```swift
@ViewBuilder
func NotchLayout() -> some View {
    let resolution = closedResolution
    VStack(alignment: .leading) {
        VStack(alignment: .leading) {
            switch resolution.surface {
            case .connectivityHUD:   NetworkConnectivityHUD(state: networkConnectivityManager.hudState, closedNotchSize: vm.closedNotchSize, effectiveClosedNotchHeight: vm.effectiveClosedNotchHeight)
            case .hello:             Spacer(); HelloAnimation().frame(width: 200, height: 80).onAppear(perform: { vm.closeHello() }).padding(.top, 40); Spacer()
            case .privacyIndicator:  PrivacyLiveActivity()
            case .batteryHUD:        BatteryTemporaryActivityView(/* unchanged arguments, :1102-1111 */).id(batteryModel.activeTemporaryHUDToken)
            case .criticalNotification, .appNotification:
                                     NotificationSneakPeekView(/* AtollNotch/UI, ui agent */)
            case .systemHUD:         InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                                         .transition(coordinator.sneakPeek.type == .capsLock ? AnyTransition.move(edge: .trailing).combined(with: .opacity) : AnyTransition.opacity)
            case .capsLockIndicator: InlineHUD(type: .constant(.capsLock), value: .constant(1.0), icon: .constant(""), hoverAnimation: $isHovering, gestureProgress: $gestureProgress).transition(AnyTransition.move(edge: .trailing).combined(with: .opacity))
            case .music:             MusicLiveActivity(secondary: resolveMusicSecondaryLiveActivity(isMusicPairingEligible: true))   // payload lookup; the badge KIND was decided by the arbiter (assert equal in DEBUG)
                                         .id("closed-music-live-activity").transition(closedLiveActivitySwapTransition)
            case .timer:             TimerLiveActivity()
            case .reminder:          ReminderLiveActivity()
            case .recording:         RecordingLiveActivity(hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
            case .download:          DownloadLiveActivity().transition(.blurReplace.animation(.interactiveSpring(dampingFraction: 1.2)))
            case .localSend:         LocalSendLiveActivity().transition(.blurReplace.animation(.interactiveSpring(dampingFraction: 1.2)))
            case .focus:             DoNotDisturbLiveActivity()
            case .extensionStandalone:
                let secondary = resolveMusicSecondaryLiveActivity(isMusicPairingEligible: closedSnapshot.musicPairingEligible)
                if let payload = resolvedExtensionStandalonePayload(excluding: extensionSecondaryPayloadID(for: secondary)) {
                    ExtensionLiveActivityStandaloneView(payload: payload, layout: extensionStandaloneLayout(for: payload, notchHeight: vm.effectiveClosedNotchHeight, isHovering: isHovering), isHovering: isHovering)
                }
            case .shelf:             ShelfInlineLiveActivity().transition(.opacity.animation(.smooth(duration: 0.25)))
            case .idle:              DynamicIslandFaceAnimation().animation(.interactiveSpring, value: musicManager.isPlayerIdle)
            case .header:            DynamicIslandHeader().frame(height: (Defaults[.enableMinimalisticUI] && isDynamicIslandMode) ? nil : max(24, vm.effectiveClosedNotchHeight))
            case .empty:             Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
            }
            switch resolution.overlay { /* replaces :1166-1249, bodies unchanged: */
            case .systemEventIndicator: SystemEventIndicatorModifier(eventType: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, sendEventBack: { _ in }).padding(.bottom, 10).padding(.leading, 4).padding(.trailing, 8)
            case .musicMarquee:     /* :1178-1185 */
            case .timerMarquee:     /* :1191-1198 */
            case .reminderMarquee:  /* :1203-1217, `if let reminder = reminderManager.activeReminder` stays */
            case .extensionMarquee: /* :1223-1246 */
            case .none:             EmptyView()
            }
        }
        // :1252 onwards (.conditionalModifier(shouldFixSizeForSneakPeek()) ...) unchanged
```

This also deletes the two copy-pasted sneak type lists (`:1113`, `:1167`; now `SneakKind.rendersAsInlineHUD` plus the overlay rule inside the resolver) and the three copies of the AirPods magic test (`:126-130`, `:1093-1095`, `DynamicIslandApp.swift:510-514`). `resolvedExtensionStandalonePayload` is now evaluated only when the extension row wins (it is evaluated, with diagnostics logging, on every body pass today).

### Step 3. `ContentView.swift:112-243` `dynamicNotchSize`

Replace `:115-188` (connectivity, inline sneak, recording, battery blocks; keep `baseSize` at `:113` and everything from `:190` on):

```swift
switch closedResolution.sizing {
case .connectivity:
    if let size = NetworkConnectivityHUDMetrics.size(for: networkConnectivityManager.hudState,
            closedNotchSize: vm.closedNotchSize, effectiveClosedNotchHeight: vm.effectiveClosedNotchHeight) { return size }
case .airPodsInlineHUD:
    return CGSize(width: max(baseSize.width, InlineHUD.airPodsListeningModeWidth(closedNotchWidth: vm.closedNotchSize.width,
            gestureProgress: gestureProgress, minimalistic: Defaults[.enableMinimalisticUI]) + notchHorizontalPadding * 2), height: baseSize.height)
case .inlineMusicTimer:
    return CGSize(width: max(baseSize.width, 460), height: baseSize.height)
case .recording:
    if let size = recordingHUDLayout.size(closedNotchSize: vm.closedNotchSize, effectiveClosedNotchHeight: vm.effectiveClosedNotchHeight) { return size }
case .battery(let spec):
    return CGSize(width: vm.closedNotchSize.width + CGFloat(spec.extraWidth), height: vm.effectiveClosedNotchHeight + CGFloat(spec.extraHeight))
case .notificationCard:
    return /* size owned by the notification UI (ui agent) */ baseSize
case .tabDriven:
    break
}
```

The deleted `style` switch (`:164-170`) and `(kind, style)` switch (`:175-184`) are `BatteryHUDSpec`.

### Step 4. `ContentView.swift:612-636` `resolvedClipShape` (and `:561-596`)

```swift
private var resolvedClipShape: AnyShape {
    switch closedResolution.clip {
    case .connectivity(let noConnection):
        if isDynamicIslandMode { return AnyShape(DynamicIslandPillShape(cornerRadius: noConnection ? 40 : 24)) }
        return AnyShape(NotchShape(topCornerRadius: activeCornerRadiusInsets.closed.top, bottomCornerRadius: noConnection ? 40 : 20))
    case .recordingExpanded:
        return isDynamicIslandMode ? AnyShape(DynamicIslandPillShape(cornerRadius: dynamicIslandPillCornerRadiusInsets.opened))
                                   : AnyShape(NotchShape(topCornerRadius: activeCornerRadiusInsets.closed.top, bottomCornerRadius: 40))
    case .battery(let spec):
        if isDynamicIslandMode { return AnyShape(DynamicIslandPillShape(cornerRadius: dynamicIslandPillCornerRadiusInsets.opened)) }
        let bottom: CGFloat = spec == .compact ? activeCornerRadiusInsets.closed.bottom : (spec == .standardFull ? 36 : 40)
        return AnyShape(NotchShape(topCornerRadius: activeCornerRadiusInsets.closed.top, bottomCornerRadius: bottom))
    case .notificationCard:
        return /* ui agent */ AnyShape(currentNotchShape)
    case .standard:
        return isDynamicIslandMode ? AnyShape(currentPillShape) : AnyShape(currentNotchShape)
    }
}
```

`activeClosedBatterySurfaceShape` (`:561-581`) and `activeClosedRecordingSurfaceShape` (`:583-596`) become dead: delete.
`isConnectivityHUDVisible` stays for `:648`, `:705-715`, `:2321-2338` (it is also `snapshot.connectivityHUDVisible`).

### Step 5. `DynamicIslandApp.swift:491-610` `calculateRequiredNotchSize`

Replace `:492-574` (connectivity, inline, recording, battery) with one switch over the same resolution:

```swift
let snapshot = ClosedNotchSnapshotBuilder.make(vm: vm, screenName: vm.screen ?? coordinator.selectedScreen,
                   musicPairingEligible: closedMusicPairingEligibleForSizing(), recordingExpanded: true)
let pad = { (size: CGSize) in addShadowPadding(to: size, isMinimalistic: Defaults[.enableMinimalisticUI]) }
switch resolveClosedNotchSurface(snapshot).sizing {
case .connectivity:
    if let size = NetworkConnectivityHUDMetrics.size(for: networkConnectivityManager.hudState, closedNotchSize: vm.closedNotchSize,
                                                    effectiveClosedNotchHeight: vm.effectiveClosedNotchHeight) { return pad(size) }
case .airPodsInlineHUD, .inlineMusicTimer:                       // the window copy has always used a flat 460 for both
    return CGSize(width: 460, height: vm.effectiveClosedNotchHeight)          // note: NOT padded, as today
case .recording:
    if let size = recordingHUDLayoutForSizing().size(closedNotchSize: vm.closedNotchSize, effectiveClosedNotchHeight: vm.effectiveClosedNotchHeight) { return pad(size) }
case .battery(let spec):
    return pad(CGSize(width: vm.closedNotchSize.width + CGFloat(spec.extraWidth), height: vm.effectiveClosedNotchHeight + CGFloat(spec.extraHeight)))
case .notificationCard:
    return pad(/* size owned by the notification UI */ openNotchSize)
case .tabDriven:
    break
}
```

`:576` onward (base size by tab, stats, shadow padding) is unchanged. The window and the view now share one decision, so the
window can no longer be sized for a surface that is not drawn. When the window is recomputed: any trigger that today re-runs
`calculateRequiredNotchSize` (sneak peek / expansion / recording / connectivity changes) keeps working; add the scheduler's
active-item change to that trigger list (step 6).

### Step 6. `DynamicIslandViewCoordinator.swift:322-410` `toggleSneakPeek`, `sneakPeekDuration`, `scheduleSneakPeekHide`, `sneakPeek.didSet` (E2)

Add `case notification(id: UUID)` to `SneakContentType` (and to `==`, `:43-66`), plus a stable `dedupeKey` per type ("volume",
"brightness", "backlight", "bluetooth", "capsLock", "music", "timer", "reminder", "ext:<bundle>:<activity>", "notification:<id>").
The 12 existing callers keep their `toggleSneakPeek(status:type:duration:value:icon:...)` signature; add one defaulted parameter
`priority: NotchSneakPriority = .normal`.

```swift
private var sneakScheduler = SneakPeekScheduler<sneakPeek>()     // sneakPeek must be Equatable & @unchecked Sendable
private var sneakWake: Task<Void, Never>?
private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

@MainActor
func toggleSneakPeek(status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0, icon: String = "",
                     title: String = "", subtitle: String = "", accentColor: Color? = nil, styleOverride: SneakPeekStyle? = nil,
                     onScreen target: NSScreen? = nil, priority: NotchSneakPriority = .normal) {
    if !status { apply(sneakScheduler.finish(dedupeKey: type.dedupeKey, now: now)); return }       // B3: only this key; B4: never gated
    let bypassed: [SneakContentType] = [.music, .timer, .reminder, .bluetoothAudio]
    if !type.isExtensionPayload, !bypassed.contains(type), !Defaults[.enableSystemHUD] { return }  // gating applies to OFFERS only (B4)
    var payload = sneakPeek(show: true, type: type, value: value, icon: icon, title: title, subtitle: subtitle,
                            accentColor: accentColor, styleOverride: styleOverride, targetScreenName: target?.localizedName)
    let kind = SneakKind(type, value: value, icon: icon)
    let (rank, sub) = NotchSneakClassifier.classify(kind: kind, priority: priority)
    let ttl: TimeInterval = { switch type { case .timer: return 10; case .reminder: return Defaults[.reminderSneakPeekDuration]; default: return duration } }()
    apply(sneakScheduler.offer(.init(dedupeKey: type.dedupeKey, rank: rank, subrank: sub,
          ttl: ttl.isFinite ? ttl : 2.0, payload: payload), now: now))       // .infinity (CapsLockManager.swift:84) -> finite; the persistent indicator is a snapshot flag
}

@MainActor private func apply(_ u: SneakPeekUpdate) {
    guard u.activeChanged || u.outcome != .noop else { return }
    withAnimation(.smooth(duration: 0.3)) { sneakPeek = sneakScheduler.active?.payload ?? { var p = sneakPeek; p.show = false; return p }() }
    sneakWake?.cancel()
    guard let deadline = sneakScheduler.nextDeadline else { return }
    sneakWake = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(max(0, deadline - (self?.now ?? deadline))))
        guard let self, !Task.isCancelled else { return }
        self.apply(self.sneakScheduler.expire(now: self.now))
    }
}
```

`sneakPeekDuration`, `scheduleSneakPeekHide`, the `DispatchQueue.main.async` hop and the `didSet` hide logic are deleted (this
kills B2-B6). Hover: `pauseSneakPeek()` / `resumeSneakPeek()` call `sneakScheduler.pause/resume` from `handleHover`
(`ContentView.swift:2321`). Lock screen: `LockScreenManager.swift:250-257` calls `clearAll`. Callers off the main thread must
hop with `Task { @MainActor in ... }` (that single hop replaces the old per-write `DispatchQueue.main.async`).
The `expandingView` slot (`:430-447`) is NOT moved into the scheduler (battery has its own token, `BatteryStatusViewModel`);
its remaining weaknesses (last writer wins, `toggleExpandingView(status:false,type:.battery)` hides any type) are unchanged.

### Step 7. Smaller edits

* `ContentView.swift:705-715` tap: before `openNotch()`, if `closedResolution.surface` is a notification surface let the notification layer act first (UI agent).
* `ContentView.swift:808-817`: unchanged logic; `coordinator.sneakPeek.show` still flips when the scheduler hides/shows.
* `ContentView.swift:523`, `:2321-2338` (hover-open guards) use `recordingHUDLayout.isVisible`; optionally switch to `closedResolution.surface == .recording` (behaviour change: hover-open becomes possible while recording is on but another surface wins). Left alone.
* `shouldFixSizeForSneakPeek` (`:2963-2979`): its `isOtherSneak` clause is true for notification kinds; check live that `fixedSize()` is wanted for the notification wings (UNVERIFIED).

### Step 8. Test wiring

Add `AtollNotch/Tests/run_arbiter.sh` to `local/tests/run.sh` (it needs ~15 s on an idle machine).

## 7. Test results (run `AtollNotch/Tests/run_arbiter.sh`)

| Area | Checks |
|---|---|
| Table, ladder, music badge order, B8, D1 (both policies), D2 (both policies), new rows, B1 geometry, overlay, purity, performance | 113 checks, including two seeded sweeps of 300,000 candidate snapshots (notification property, purity and policy plumbing) |
| T1 differential (13 checks) | exhaustive E1 (393,216 raw states, sticky ladder x expansion slot), E2 (737,280 raw, structure x every sneak kind), E3 (552,960 raw, geometry owners), plus E4: 1,000,000 seeded samples of the full space (raw product > 10^9); every difference classified, 4 allow-list entries all exercised |
| T2 scenarios (59 checks) | B2 (3 variants), B3, B4, B5 (3), B6 (2), B10 (2), preempt/resume, nested preemption, FIFO + subrank, dedupe, cap and eviction, invalid/STICKY ttl, clock monotonicity, pause/resume, clearAll, replay determinism |
| T2 fuzz (6 checks) | 100,000 seeded sequences (about 3.15 million operations, invariants checked after EVERY operation): one active item; `show` implies a pending expiry unless paused; deadline strictly after the clock; stale/foreign tokens never change any state; `finish(token)` removes exactly that token; `finish(dedupeKey:)` removes only that key; remaining time never grows; waiting items never outrank the active one; queue sorted by key and within capacity; unique tokens and keys; no token silently lost or invented |
| Determinism (inside the fuzz checks) | 20,000 sequences run three ways (replay, replay, and with extra redundant `expire()` calls interleaved before each event): bit-identical state after every event |
| Soak | 1,000,000 offers over 40 keys: queue peak 5, drains to empty |
| Performance | `resolveClosedNotchSurface` 40-70 ns per call at `-O` on this Mac, depending on machine load (budget 5,000 ns) |
| Total | 192 PASS lines, 0 FAIL, about 15 s idle (about 35 s while other builds ran) |

Mutation check (run by hand, not part of the script): 11 deliberately broken copies of the Core files were each run through the suite and
each one failed it (2 to 11 FAIL lines): caps lock rank moved below music, timer overlay ignoring `hideOnClosed`, equal rank
preempting, `finish` ignoring the token, evicting the newest instead of the oldest, recording sized when it did not win, music
badge order swapped, promotion at the wake time instead of the logical expiry, a preempted item losing its remaining ttl,
privacy keeping the expansion guard, download keeping its old rank.

## 8. Not verifiable without the live app

* Anything visual: the notification surfaces, the card, window growth, clip shapes, transitions (`closedLiveActivitySwapTransition`, `.blurReplace`) when the surface changes through the new `switch` (the old chain was one `if / else if` expression, the new one is a `switch`: SwiftUI identity/animation behaviour of branch changes is expected to match but is UNVERIFIED).
* Compilation of every snippet in section 6 against SwiftUI/Defaults (no Xcode here).
* The D2 consequence (no inline volume HUD while the camera is on) and the D1 consequence (download over music while it runs) as user experience.
* Timing under real load: the single wake `Task` per active item; main-actor hop latency; behaviour when the Mac sleeps (use `systemUptime`, which excludes sleep, so a sleeping Mac pauses TTLs; if wall-clock expiry is wanted use `ContinuousClock`).
* Multi-display: the snapshot is built per screen name, as `isSneakPeekVisibleOnCurrentScreen` already is; the window copy previously ignored the per-screen battery check (B11/R12). Needs two displays.
* Caps lock with `enableCapsLockIndicator` off: the HUD that used to stay until release (infinite duration) becomes a finite one; product decision.
